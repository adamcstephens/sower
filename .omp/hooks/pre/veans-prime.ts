import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function veansPrime(pi: ExtensionAPI): void {
  const prime = async (_event: unknown, ctx: { cwd: string }) => {
    await pi.exec("veans", ["prime"], { cwd: ctx.cwd });
  };

  pi.on("session_start", prime);
  pi.on("session_before_compact", prime);
}
