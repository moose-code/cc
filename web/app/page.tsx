import { Header } from "@/components/Header";
import { EngineFeed } from "@/components/EngineFeed";
import { TradePanel } from "@/components/TradePanel";
import { Footer } from "@/components/Footer";

export default function Page() {
  return (
    <main className="app">
      <Header />
      <div className="body">
        <EngineFeed />
        <TradePanel />
      </div>
      <Footer />
    </main>
  );
}
