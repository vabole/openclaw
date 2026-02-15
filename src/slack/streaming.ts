import type { WebClient } from "@slack/web-api";
import { logVerbose } from "../globals.js";

type ChatStreamer = ReturnType<WebClient["chatStream"]>;

export type SlackStreamSession = {
  streamer: ChatStreamer;
  channel: string;
  threadTs: string;
  stopped: boolean;
};

export async function startSlackStream(params: {
  client: WebClient;
  channel: string;
  threadTs: string;
  text?: string;
  bufferSize?: number;
}): Promise<SlackStreamSession> {
  const streamer = params.client.chatStream({
    channel: params.channel,
    thread_ts: params.threadTs,
    ...(typeof params.bufferSize === "number" ? { buffer_size: params.bufferSize } : {}),
  });
  const session: SlackStreamSession = {
    streamer,
    channel: params.channel,
    threadTs: params.threadTs,
    stopped: false,
  };
  if (params.text) {
    await appendSlackStream({ session, text: params.text });
  }
  return session;
}

export async function appendSlackStream(params: {
  session: SlackStreamSession;
  text: string;
}): Promise<void> {
  const text = params.text;
  if (!text || params.session.stopped) {
    return;
  }
  await params.session.streamer.append({ markdown_text: text });
  logVerbose(`slack-stream: appended ${text.length} chars`);
}

export async function stopSlackStream(params: {
  session: SlackStreamSession;
  text?: string;
}): Promise<void> {
  if (params.session.stopped) {
    return;
  }
  params.session.stopped = true;
  await params.session.streamer.stop(params.text ? { markdown_text: params.text } : undefined);
  logVerbose(
    `slack-stream: stopped channel=${params.session.channel} thread=${params.session.threadTs}`,
  );
}
