import { EngineFeed } from "@/components/EngineFeed";
import { EnginePanel } from "@/components/EnginePanel";
import { Flywheel } from "@/components/Flywheel";

export default function Page() {
  return (
    <>
      <Flywheel />
      <div className="body">
        <EngineFeed />
        <EnginePanel />
      </div>
    </>
  );
}
