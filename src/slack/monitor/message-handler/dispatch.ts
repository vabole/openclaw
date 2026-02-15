import type { ReplyDispatchKind } from "../../../auto-reply/reply/reply-dispatcher.js";
import type { ReplyPayload } from "../../../auto-reply/types.js";
import type { PreparedSlackMessage } from "./types.js";
import { resolveHumanDelayConfig } from "../../../agents/identity.js";
import { dispatchInboundMessage } from "../../../auto-reply/dispatch.js";
import { clearHistoryEntriesIfEnabled } from "../../../auto-reply/reply/history.js";
import { createReplyDispatcherWithTyping } from "../../../auto-reply/reply/reply-dispatcher.js";
import { isSilentReplyText, SILENT_REPLY_TOKEN } from "../../../auto-reply/tokens.js";
import { removeAckReactionAfterReply } from "../../../channels/ack-reactions.js";
import { logAckFailure, logTypingFailure } from "../../../channels/logging.js";
import { createReplyPrefixOptions } from "../../../channels/reply-prefix.js";
import { createTypingCallbacks } from "../../../channels/typing.js";
import { resolveStorePath, updateLastRoute } from "../../../config/sessions.js";
import { danger, logVerbose, shouldLogVerbose } from "../../../globals.js";
import { removeSlackReaction } from "../../actions.js";
import {
  appendSlackStream,
  startSlackStream,
  stopSlackStream,
  type SlackStreamSession,
} from "../../streaming.js";
import { resolveSlackThreadTargets } from "../../threading.js";
import { createSlackReplyDeliveryPlan, deliverReplies, resolveSlackThreadTs } from "../replies.js";

function hasMedia(payload: ReplyPayload): boolean {
  return Boolean(payload.mediaUrl) || (payload.mediaUrls?.length ?? 0) > 0;
}

export async function dispatchPreparedSlackMessage(prepared: PreparedSlackMessage) {
  const { ctx, account, message, route } = prepared;
  const cfg = ctx.cfg;
  const runtime = ctx.runtime;

  if (prepared.isDirectMessage) {
    const sessionCfg = cfg.session;
    const storePath = resolveStorePath(sessionCfg?.store, {
      agentId: route.agentId,
    });
    await updateLastRoute({
      storePath,
      sessionKey: route.mainSessionKey,
      deliveryContext: {
        channel: "slack",
        to: `user:${message.user}`,
        accountId: route.accountId,
      },
      ctx: prepared.ctxPayload,
    });
  }

  const { statusThreadTs } = resolveSlackThreadTargets({
    message,
    replyToMode: ctx.replyToMode,
  });

  const messageTs = message.ts ?? message.event_ts;
  const incomingThreadTs = message.thread_ts;
  let didSetStatus = false;

  // Shared mutable ref for "replyToMode=first". Both tool + auto-reply flows
  // mark this to ensure only the first reply is threaded.
  const hasRepliedRef = { value: false };
  const replyPlan = createSlackReplyDeliveryPlan({
    replyToMode: ctx.replyToMode,
    incomingThreadTs,
    messageTs,
    hasRepliedRef,
  });

  const typingTarget = statusThreadTs ? `${message.channel}/${statusThreadTs}` : message.channel;
  const typingCallbacks = createTypingCallbacks({
    start: async () => {
      didSetStatus = true;
      await ctx.setSlackThreadStatus({
        channelId: message.channel,
        threadTs: statusThreadTs,
        status: "is typing...",
      });
    },
    stop: async () => {
      if (!didSetStatus) {
        return;
      }
      didSetStatus = false;
      await ctx.setSlackThreadStatus({
        channelId: message.channel,
        threadTs: statusThreadTs,
        status: "",
      });
    },
    onStartError: (err) => {
      logTypingFailure({
        log: (message) => runtime.error?.(danger(message)),
        channel: "slack",
        action: "start",
        target: typingTarget,
        error: err,
      });
    },
    onStopError: (err) => {
      logTypingFailure({
        log: (message) => runtime.error?.(danger(message)),
        channel: "slack",
        action: "stop",
        target: typingTarget,
        error: err,
      });
    },
  });

  const { onModelSelected, ...prefixOptions } = createReplyPrefixOptions({
    cfg,
    agentId: route.agentId,
    channel: "slack",
    accountId: route.accountId,
  });
  const streamThreadHint = resolveSlackThreadTs({
    replyToMode: ctx.replyToMode,
    incomingThreadTs,
    messageTs,
    hasReplied: false,
  });
  const useStreaming = account.config.streaming === true && Boolean(streamThreadHint);
  if (account.config.streaming === true && !useStreaming) {
    logVerbose("slack-stream: disabled for this response (thread_ts unavailable)");
  }

  let streamSession: SlackStreamSession | null = null;
  let streamFailed = false;
  let streamedText = "";

  const stopStreamIfActive = async () => {
    if (!streamSession) {
      return;
    }
    try {
      await stopSlackStream({ session: streamSession });
    } catch (err) {
      streamFailed = true;
      logVerbose(`slack-stream: failed to stop stream: ${String(err)}`);
    } finally {
      streamSession = null;
      streamedText = "";
    }
  };

  const deliverNormal = async (payload: ReplyPayload, replyThreadTs?: string) => {
    await deliverReplies({
      replies: [payload],
      target: prepared.replyTarget,
      token: ctx.botToken,
      accountId: account.accountId,
      runtime,
      textLimit: ctx.textLimit,
      replyThreadTs,
    });
    replyPlan.markSent();
  };

  const resolveStreamDelta = (nextText: string): string => {
    if (!streamedText) {
      streamedText = nextText;
      return nextText;
    }
    if (nextText === streamedText) {
      return "";
    }
    if (nextText.startsWith(streamedText)) {
      const delta = nextText.slice(streamedText.length);
      streamedText = nextText;
      return delta;
    }
    if (streamedText.startsWith(nextText)) {
      streamedText = nextText;
      return "";
    }
    streamedText = `${streamedText}\n${nextText}`;
    return `\n${nextText}`;
  };

  const deliverWithOptionalStreaming = async (payload: ReplyPayload, kind: ReplyDispatchKind) => {
    const replyThreadTs = replyPlan.nextThreadTs();
    const effectiveThreadTs = replyThreadTs?.trim() || undefined;
    const text = payload.text?.trim() ?? "";
    const canStreamText =
      useStreaming &&
      !streamFailed &&
      kind !== "tool" &&
      !hasMedia(payload) &&
      Boolean(effectiveThreadTs) &&
      Boolean(text) &&
      !isSilentReplyText(text, SILENT_REPLY_TOKEN);

    if (!canStreamText) {
      await stopStreamIfActive();
      await deliverNormal(payload, replyThreadTs);
      return;
    }
    if (!effectiveThreadTs) {
      await stopStreamIfActive();
      await deliverNormal(payload, replyThreadTs);
      return;
    }

    try {
      if (!streamSession || streamSession.threadTs !== effectiveThreadTs) {
        await stopStreamIfActive();
        streamSession = await startSlackStream({
          client: ctx.app.client,
          channel: message.channel,
          threadTs: effectiveThreadTs,
          text,
        });
        streamedText = text;
      } else {
        const delta = resolveStreamDelta(text);
        if (delta) {
          await appendSlackStream({
            session: streamSession,
            text: delta,
          });
        }
      }
      replyPlan.markSent();
    } catch (err) {
      streamFailed = true;
      logVerbose(`slack-stream: stream API failed; falling back for this response: ${String(err)}`);
      await stopStreamIfActive();
      await deliverNormal(payload, replyThreadTs);
    }
  };

  const { dispatcher, replyOptions, markDispatchIdle } = createReplyDispatcherWithTyping({
    ...prefixOptions,
    humanDelay: resolveHumanDelayConfig(cfg, route.agentId),
    deliver: (payload, info) => deliverWithOptionalStreaming(payload, info.kind),
    onError: (err, info) => {
      runtime.error?.(danger(`slack ${info.kind} reply failed: ${String(err)}`));
      typingCallbacks.onIdle?.();
    },
    onReplyStart: typingCallbacks.onReplyStart,
    onIdle: typingCallbacks.onIdle,
  });

  const dispatchResult = await (async () => {
    try {
      return await dispatchInboundMessage({
        ctx: prepared.ctxPayload,
        cfg,
        dispatcher,
        replyOptions: {
          ...replyOptions,
          skillFilter: prepared.channelConfig?.skills,
          hasRepliedRef,
          disableBlockStreaming: useStreaming
            ? false
            : typeof account.config.blockStreaming === "boolean"
              ? !account.config.blockStreaming
              : undefined,
          onModelSelected,
        },
      });
    } finally {
      markDispatchIdle();
      await stopStreamIfActive();
    }
  })();
  const { queuedFinal, counts } = dispatchResult;

  const anyReplyDelivered = queuedFinal || (counts.block ?? 0) > 0 || (counts.final ?? 0) > 0;

  if (!anyReplyDelivered) {
    if (prepared.isRoomish) {
      clearHistoryEntriesIfEnabled({
        historyMap: ctx.channelHistories,
        historyKey: prepared.historyKey,
        limit: ctx.historyLimit,
      });
    }
    return;
  }

  if (shouldLogVerbose()) {
    const finalCount = counts.final;
    logVerbose(
      `slack: delivered ${finalCount} reply${finalCount === 1 ? "" : "ies"} to ${prepared.replyTarget}`,
    );
  }

  removeAckReactionAfterReply({
    removeAfterReply: ctx.removeAckAfterReply,
    ackReactionPromise: prepared.ackReactionPromise,
    ackReactionValue: prepared.ackReactionValue,
    remove: () =>
      removeSlackReaction(
        message.channel,
        prepared.ackReactionMessageTs ?? "",
        prepared.ackReactionValue,
        {
          token: ctx.botToken,
          client: ctx.app.client,
        },
      ),
    onError: (err) => {
      logAckFailure({
        log: logVerbose,
        channel: "slack",
        target: `${message.channel}/${message.ts}`,
        error: err,
      });
    },
  });

  if (prepared.isRoomish) {
    clearHistoryEntriesIfEnabled({
      historyMap: ctx.channelHistories,
      historyKey: prepared.historyKey,
      limit: ctx.historyLimit,
    });
  }
}
