import { TradePanel } from "@/components/TradePanel";

// The coin swap on its own page; the mobile nav links here, the home page carries it beside the feed on desktop.
export default function Page() {
  return (
    <main className="page">
      <TradePanel />
    </main>
  );
}
