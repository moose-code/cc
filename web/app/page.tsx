import { EngineFeed, EngineProgress } from "@/components/EngineFeed";
import { Flywheel } from "@/components/Flywheel";
import { StatsBar } from "@/components/StatsBar";
import { TradePanel } from "@/components/TradePanel";

export default function Page() {
  return (
    <div className="home">
      <Flywheel />
      <div className="home-body">
        <StatsBar />
        <EngineFeed />
        <div className="rail">
          <EngineProgress />
          <TradePanel />
        </div>
      </div>
    </div>
  );
}
