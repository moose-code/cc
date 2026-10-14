import { EngineFeed } from "@/components/EngineFeed";
import { Flywheel } from "@/components/Flywheel";
import { TradePanel } from "@/components/TradePanel";

export default function Page() {
  return (
    <>
      <Flywheel />
      <div className="body">
        <EngineFeed />
        <TradePanel />
      </div>
    </>
  );
}
