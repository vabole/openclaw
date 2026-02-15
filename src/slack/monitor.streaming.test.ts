import { beforeEach, describe, expect, it } from "vitest";
import { resetInboundDedupe } from "../auto-reply/reply/inbound-dedupe.js";
import {
  defaultSlackTestConfig,
  flush,
  getSlackHandlers,
  getSlackTestState,
  resetSlackTestState,
  waitForSlackEvent,
} from "./monitor.test-helpers.js";

const { monitorSlackProvider } = await import("./monitor.js");

const slackTestState = getSlackTestState();
const { replyMock, sendMock, chatStreamMock, chatStreamAppendMock, chatStreamStopMock } =
  slackTestState;

type ReplyHookOptions = {
  onBlockReply?: (payload: { text?: string }) => Promise<void> | void;
};

describe("monitorSlackProvider native streaming", () => {
  beforeEach(() => {
    resetInboundDedupe();
    resetSlackTestState(defaultSlackTestConfig());
  });

  it("streams threaded block replies into a single live-updating message", async () => {
    replyMock.mockImplementation(async (_ctx: unknown, opts?: ReplyHookOptions) => {
      await opts?.onBlockReply?.({ text: "first block" });
      await opts?.onBlockReply?.({ text: "second block" });
      return [];
    });
    slackTestState.config = {
      messages: {
        responsePrefix: "PFX",
        ackReaction: "👀",
        ackReactionScope: "group-mentions",
      },
      channels: {
        slack: {
          dm: { enabled: true, policy: "open", allowFrom: ["*"] },
          replyToMode: "all",
          streaming: true,
        },
      },
    };

    const controller = new AbortController();
    const run = monitorSlackProvider({
      botToken: "bot-token",
      appToken: "app-token",
      abortSignal: controller.signal,
    });

    await waitForSlackEvent("message");
    const handler = getSlackHandlers()?.get("message");
    if (!handler) {
      throw new Error("Slack message handler not registered");
    }
    await handler({
      event: {
        type: "message",
        user: "U1",
        text: "hello",
        ts: "123",
        channel: "C1",
        channel_type: "im",
      },
    });
    await flush();
    controller.abort();
    await run;

    expect(chatStreamMock).toHaveBeenCalledTimes(1);
    expect(chatStreamMock).toHaveBeenCalledWith({ channel: "C1", thread_ts: "123" });
    expect(chatStreamAppendMock).toHaveBeenCalledTimes(2);
    expect(chatStreamAppendMock.mock.calls[0]?.[0]).toMatchObject({
      markdown_text: expect.stringContaining("first block"),
    });
    expect(chatStreamAppendMock.mock.calls[1]?.[0]).toMatchObject({
      markdown_text: expect.stringContaining("second block"),
    });
    expect(chatStreamStopMock).toHaveBeenCalledTimes(1);
    expect(sendMock).not.toHaveBeenCalled();
  });

  it("falls back to normal delivery for the rest of the response after stream API failure", async () => {
    replyMock.mockImplementation(async (_ctx: unknown, opts?: ReplyHookOptions) => {
      await opts?.onBlockReply?.({ text: "first block" });
      await opts?.onBlockReply?.({ text: "second block" });
      return [];
    });
    let appendCount = 0;
    chatStreamAppendMock.mockImplementation(async () => {
      appendCount += 1;
      if (appendCount === 1) {
        throw new Error("missing_scope");
      }
      return { ok: true };
    });
    slackTestState.config = {
      messages: {
        responsePrefix: "PFX",
        ackReaction: "👀",
        ackReactionScope: "group-mentions",
      },
      channels: {
        slack: {
          dm: { enabled: true, policy: "open", allowFrom: ["*"] },
          replyToMode: "all",
          streaming: true,
        },
      },
    };

    const controller = new AbortController();
    const run = monitorSlackProvider({
      botToken: "bot-token",
      appToken: "app-token",
      abortSignal: controller.signal,
    });

    await waitForSlackEvent("message");
    const handler = getSlackHandlers()?.get("message");
    if (!handler) {
      throw new Error("Slack message handler not registered");
    }
    await handler({
      event: {
        type: "message",
        user: "U1",
        text: "hello",
        ts: "123",
        channel: "C1",
        channel_type: "im",
      },
    });
    await flush();
    controller.abort();
    await run;

    expect(chatStreamMock).toHaveBeenCalledTimes(1);
    expect(sendMock).toHaveBeenCalledTimes(2);
    expect(sendMock.mock.calls[0]?.[2]).toMatchObject({ threadTs: "123" });
    expect(sendMock.mock.calls[1]?.[2]).toMatchObject({ threadTs: "123" });
  });

  it("falls back to normal delivery when thread_ts is unavailable", async () => {
    replyMock.mockResolvedValue({ text: "normal reply" });
    slackTestState.config = {
      messages: {
        responsePrefix: "PFX",
        ackReaction: "👀",
        ackReactionScope: "group-mentions",
      },
      channels: {
        slack: {
          dm: { enabled: true, policy: "open", allowFrom: ["*"] },
          replyToMode: "off",
          streaming: true,
        },
      },
    };

    const controller = new AbortController();
    const run = monitorSlackProvider({
      botToken: "bot-token",
      appToken: "app-token",
      abortSignal: controller.signal,
    });

    await waitForSlackEvent("message");
    const handler = getSlackHandlers()?.get("message");
    if (!handler) {
      throw new Error("Slack message handler not registered");
    }
    await handler({
      event: {
        type: "message",
        user: "U1",
        text: "hello",
        ts: "123",
        channel: "C1",
        channel_type: "im",
      },
    });
    await flush();
    controller.abort();
    await run;

    expect(chatStreamMock).not.toHaveBeenCalled();
    expect(sendMock).toHaveBeenCalledTimes(1);
    expect(sendMock.mock.calls[0]?.[2]).toMatchObject({ threadTs: undefined });
  });
});
