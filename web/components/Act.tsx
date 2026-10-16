"use client";

import { useAccount } from "wagmi";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import { useTx, type Write } from "@/lib/tx";

// A button that runs wagmi writes with the connected account: `steps` receives
// `write` (gas estimate, send, receipt) and may call it more than once. A
// disconnected visitor sees a connect button. The error of a failed step shows below.
export function Act({
  label,
  steps,
  disabled,
  title,
  secondary,
}: {
  label: string;
  steps: (write: Write) => Promise<void>;
  disabled?: boolean;
  title?: string;
  secondary?: boolean;
}) {
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { run, pending, err } = useTx();
  return (
    <>
      {isConnected ? (
        <button className={`action${secondary ? " secondary" : ""}`} onClick={() => run(steps)} disabled={disabled || pending} title={title}>
          {pending ? "confirm in wallet…" : label}
        </button>
      ) : (
        <button className={`action${secondary ? " secondary" : ""}`} onClick={openConnectModal}>
          connect to {label}
        </button>
      )}
      {err && <p className="panel-note err">{err}</p>}
    </>
  );
}
