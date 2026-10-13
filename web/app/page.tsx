import { EngineFeed } from "@/components/EngineFeed";
import { TradePanel } from "@/components/TradePanel";

export default function Page() {
  return (
    <div className="body">
      <EngineFeed />
      <TradePanel />
    </div>
  );
}
