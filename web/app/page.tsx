import { EngineFeed } from "@/components/EngineFeed";
import { EnginePanel } from "@/components/EnginePanel";

export default function Page() {
  return (
    <div className="body">
      <EngineFeed />
      <EnginePanel />
    </div>
  );
}
