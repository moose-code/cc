import type { Metadata } from "next";
import type { ReactNode } from "react";
import Link from "next/link";
import "./faq.css";

export const metadata: Metadata = {
  title: "FAQ",
  description: "Why CC keeps buying Credits, how inventory circulates, and where fees and royalties go.",
};

type Question = { question: string; answer: ReactNode };

const questions: Question[] = [
  {
    question: "what is CC trying to build around Credits?",
    answer: (
      <p>
        a recurring market participant. $CC trading fees fund a standing ETH bid for Credits, and a $BALANCE treasury adds
        a second one. the engine acquires Credits by rating, offers individual Credits back to collectors, assembles groups
        of 80 into Statements, and converts unsold Statements into $BALANCE that buys more Credits.
      </p>
    ),
  },
  {
    question: "is this just a system for buying and relisting NFTs?",
    answer: (
      <p>
        relisting is one path, but the engine is designed for continued turnover. an acquired Credit enters a sale
        window with a declining ask. after that window, unsold Credits can be composed into Statements. a Statement is
        offered for ETH first; if it does not sell, it can be converted into $BALANCE, which funds more acquisitions.
        neither path requires a buyer to accept a permanently increasing markup, although each sale still has a floor.
      </p>
    ),
  },
  {
    question: "how is the bid calculated?",
    answer: (
      <p>
        each Credit has a rating assigned by the original Credits system, and each rating point is worth one $BALANCE.
        the ETH bid pays 90 to 100% of that value, priced at a protected $BALANCE price: the lower of the recent and live
        pool prices, bounded by a slowly updated reference. each purchase moves the bid toward 90%, and it recovers toward
        100% over time. so the bid follows the price of $BALANCE instead of climbing without limit. the limits and timing
        can be changed by the operator.
      </p>
    ),
  },
  {
    question: "what happens if Credit prices fall?",
    answer: (
      <p>
        the bid follows the value of a Credit&apos;s points in $BALANCE, not Credit listings, so it does not chase the
        market down or up on its own. resale prices decline over their windows but stop at floors tied to recorded cost
        and value. unsold Statements can still be converted into $BALANCE. a deep decline in Credits or $BALANCE can
        still leave inventory unsold and slow the cycle; continuous sales are never guaranteed.
      </p>
    ),
  },
  {
    question: "can i sell any Credit to the engine?",
    answer: (
      <p>
        yes, two ways. for ETH at the current bid, while the engine has enough available ETH (some of the pot is kept in
        reserve for processing). or for $BALANCE on the <Link href="/exchange">exchange</Link> page, at 80% of the
        Credit&apos;s rating, while the treasury has enough $BALANCE available. price protection can lower either quote,
        and buying can be limited by a pause, spending rules, or a temporary return lock on Credits the engine sold. a
        visible quote does not guarantee execution later in the block.
      </p>
    ),
  },
  {
    question: "is the CC bid a floor price for Credits?",
    answer: (
      <p>
        there is a public offer while the engine is funded and accepting Credits, but no guaranteed collection floor.
        the bid moves with $BALANCE&apos;s price and with acquisitions, and it can be altered or paused by the operator.
        a Credit with more rating points receives a larger quote at the same rate.
      </p>
    ),
  },
  {
    question: "what happens to Credits CC buys?",
    answer: (
      <p>
        each acquired Credit, whether bought with ETH or $BALANCE, enters the engine inventory and is offered for sale at
        a price that declines over a configurable window. if still held when its window has passed, it can be included in
        a group of 80 that is burned to mint a new Statement. anyone can trigger eligible composition.
      </p>
    ),
  },
  {
    question: "what happens when a Statement is made?",
    answer: (
      <p>
        the 80 original Credits are burned through Jack Butcher&rsquo;s Statements contract, and the resulting Statement
        is held by CC. the engine offers it for ETH at 1.5 times a reference based on its rated value. if it is still
        unsold after an hour, anyone can convert it into $BALANCE through the treasury, at one $BALANCE per rating point.
      </p>
    ),
  },
  {
    question: "why would i buy a Credit or Statement from CC?",
    answer: (
      <p>
        you can buy an individual Credit during its descending sale window, or a Statement assembled by the engine.
        the prices are public and change over time. you are buying the original NFTs, transferred from the engine,
        rather than a separate CC derivative.
      </p>
    ),
  },
  {
    question: "where do CC trading fees go?",
    answer: (
      <p>
        the configured ongoing pool fee is 6.9% of trading volume. at that baseline, 6.21% of volume goes to the
        acquisition engine and 0.69% goes to the artcoins protocol fee leg. the engine&apos;s share is booked into the
        ETH buying pot. these fees apply to trades in the CC pool, including buys and sells.
      </p>
    ),
  },
  {
    question: "how does the artist get paid?",
    answer: (
      <p>
        3% of every Credit purchase, in ETH or $BALANCE, is paid on top of the price to a split that sends 2.5% to the
        artist and 0.5% to the operator; the seller receives the full quoted amount. 3% of the price of every Credit or
        Statement the engine resells goes to the same split. these are CC engine payments, separate from any fees an
        external marketplace may charge.
      </p>
    ),
  },
  {
    question: "what happens to ETH from a Statement or Credit sale?",
    answer: (
      <p>
        a Statement sale sends 3% to the split (2.5% artist, 0.5% operator) and the remaining 97% to the buying pot, as
        the chart above shows. an individual Credit resale returns its recorded cost to the buying pot; anything above
        that cost funds CC buybacks.
      </p>
    ),
  },
  {
    question: "is CC burned?",
    answer: (
      <p>
        yes, in two ways today. when an individual Credit resells above its recorded cost, the excess funds an onchain
        buyback that swaps ETH for CC and burns it. and swapping one Credit for another in the engine costs a CC fee that
        is burned. a separate burn to redeem path is planned for later (see the claim reserve below).
      </p>
    ),
  },
  {
    question: "how does $BALANCE fit into the flywheel?",
    answer: (
      <p>
        it is a second, separate cycle next to the ETH one. a Statement left unsold for an hour is converted into
        $BALANCE at one per rating point. 10% of each conversion is set aside as a claim reserve; the other 90% joins the
        treasury&apos;s working funds, which pay holders who sell Credits on the exchange page. those Credits join the same
        inventory, get composed into Statements, and the cycle repeats. $BALANCE never refills the ETH buying pot.
      </p>
    ),
  },
  {
    question: "what is the claim reserve? (future: burn CC to redeem)",
    answer: (
      <p>
        10% of every Statement conversion is held in the treasury as a claim reserve. a future path, not active today,
        would let CC holders burn CC for a proportional share of it. until it is switched on, holding CC gives no claim
        on it. when it does activate, it is a claim on an operator managed reserve: the operator can pause it, return
        backing to working funds while paused, or change its fee, so the amount per CC can change.
      </p>
    ),
  },
  {
    question: "how was CC distributed at launch?",
    answer: (
      <p>
        the launch configuration specifies a supply of one billion CC. it sends the supply to the initial ETH trading
        liquidity through the artcoins factory and its locker, with no separate presale, team token allocation,
        airdrop, or token distribution extension configured. holding CC does not grant a claim on the engine&rsquo;s ETH
        or NFTs.
      </p>
    ),
  },
  {
    question: "who controls the engine?",
    answer: (
      <p>
        CC is autonomous in the sense that its public rules execute onchain and anyone can use its permitted actions.
        the operator still controls important settings, including the bid, sale rules, payment percentages, the
        $BALANCE treasury&apos;s switches, pauses, and some contract replacements. there is no delay on those setting
        changes. the code supports one way locks for some permissions, but do not assume every permission has been
        locked. current settings can be inspected onchain.
      </p>
    ),
  },
  {
    question: "is CC part of Jack Butcher’s Credits project?",
    answer: (
      <p>
        CC is an independent project built around the existing Credits and Statements contracts. Jack Butcher created
        those artworks and their composition system. CC operates its own acquisition and resale rules and is not
        affiliated with or endorsed by Jack or the original Credits project. read the
        {" "}<a href="https://jack.art/credits/" target="_blank" rel="noreferrer">original project</a>
        {" "}for its own history and mechanics.
      </p>
    ),
  },
];

// value mode: the ceiling is 100% of the points' value at the protected $BALANCE price (it moves with that price); the
// bid sits at it, drops toward the 90% floor at each buy and recovers. drawn with the ceiling wandering, not climbing
function BidIllustration() {
  return (
    <svg className="faq-bid-drawing" viewBox="0 0 480 174" role="img" aria-label="illustration: the bid sits at 100% of the Credit's $BALANCE value, which moves with the $BALANCE price; a purchase drops it toward 90%, then it recovers">
      <line x1="14" y1="145" x2="466" y2="145" className="faq-axis" />
      <line x1="14" y1="16" x2="14" y2="145" className="faq-axis" />
      {/* the ceiling: 100% of value, moving with $BALANCE */}
      <path className="faq-axis" strokeDasharray="4 4" fill="none" d="M24 70 C90 60 140 52 200 58 S300 82 360 74 S430 54 456 50" />
      {/* the bid: at the ceiling, a drop at each buy, then recovery back to it */}
      <path className="faq-bid-path" d="M24 70 C90 60 140 52 186 57 L190 84 C210 80 225 66 248 64 C280 70 310 80 336 77 L340 104 C360 99 380 82 404 66 C425 58 440 53 456 50" />
      <circle cx="190" cy="84" r="5" className="faq-drop-dot" />
      <circle cx="340" cy="104" r="5" className="faq-drop-dot" />
      <text x="190" y="106" textAnchor="middle" className="faq-bid-label">buy</text>
      <text x="340" y="126" textAnchor="middle" className="faq-bid-label">buy</text>
      <text x="40" y="44" className="faq-bid-label">100% of value (moves with $BALANCE)</text>
      <text x="380" y="98" className="faq-bid-label">recovers</text>
      <text x="20" y="165" className="faq-bid-label">time →</text>
    </svg>
  );
}

function InventoryPaths() {
  return (
    <div className="faq-paths" tabIndex={0} aria-label="scrollable diagram of the CC flywheel">
      <svg
        className="faq-paths-diagram"
        style={{ display: "block", width: "100%", minWidth: 940, height: "auto", fontFamily: "var(--mono)" }}
        viewBox="0 0 1360 600"
        role="img"
        aria-labelledby="faq-paths-title faq-paths-description"
      >
        <title id="faq-paths-title">the CC flywheel</title>
        <desc id="faq-paths-description">
          CC trading fees fill an ETH buying pot that acquires Credits through OpenSea listings, CreditStrategy, and direct sales. Credits can be sold individually
          or composed in groups of 80 into Statements. ETH sales return funds to the ETH buying pot. A Statement left
          unsold can be redeemed for BALANCE; the treasury then buys more Credits with BALANCE through the exchange,
          continuing a separate cycle. A future path, not active, would let CC holders burn CC for a share of the
          treasury's claim reserve.
        </desc>
        <defs>
          <marker id="faq-paths-arrow" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto" markerUnits="userSpaceOnUse">
            <path d="M0 0 L9 4.5 L0 9 Z" fill="#e5007e" stroke="none" />
          </marker>
          <marker id="faq-paths-source-arrow" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto" markerUnits="userSpaceOnUse">
            <path d="M0 0 L9 4.5 L0 9 Z" fill="#8a877e" stroke="none" />
          </marker>
        </defs>

        <g className="faq-paths-connections" aria-hidden="true">
          <path d="M445 115 H493" fill="none" stroke="#e5007e" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M678 115 H728" fill="none" stroke="#e5007e" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M840 146 V189 H380 V233" fill="none" stroke="#e5007e" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M840 189 H775 V233" fill="none" stroke="#e5007e" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M380 307 V366 H455 V403" fill="none" stroke="#e5007e" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M775 307 V403" fill="none" stroke="#e5007e" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M946 271 H995" fill="none" stroke="#976ba9" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M1140 307 V403" fill="none" stroke="#976ba9" strokeWidth={2.8} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          {/* future: the claim reserve to a CC burn to redeem, dashed and grey to read as not active */}
          <path d="M1142 476 V527" className="faq-paths-future" fill="none" stroke="#8a877e" strokeWidth={2.4} strokeLinecap="round" strokeLinejoin="round" strokeDasharray="6 6" markerEnd="url(#faq-paths-source-arrow)" />

          <path d="M260 440 H151 V49 H584 V83" className="faq-paths-recycle" fill="none" stroke="#e5007e" strokeWidth={3.2} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
          <path d="M1289 439 H1322 V19 H840 V83" className="faq-paths-recycle" fill="none" stroke="#976ba9" strokeWidth={3.2} strokeLinecap="round" strokeLinejoin="round" markerEnd="url(#faq-paths-arrow)" />
        </g>

        <g className="faq-paths-box">
          <rect x="245" y="84" width="200" height="62" fill="#f6f5f0" stroke="#d9d7cf" strokeWidth={1.7} />
          <text x="345" y="115" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">$CC trading fees</text>
        </g>
        <g className="faq-paths-box">
          <rect x="493" y="84" width="185" height="62" fill="#f6f5f0" stroke="#d9d7cf" strokeWidth={1.7} />
          <text x="585" y="115" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">ETH buying pot</text>
        </g>
        <g className="faq-paths-box">
          <rect x="728" y="84" width="218" height="62" fill="#f6f5f0" stroke="#d9d7cf" strokeWidth={1.7} />
          <text x="837" y="115" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">Credits acquired</text>
        </g>
        <g className="faq-paths-sources" aria-label="Credit acquisition routes">
          <text x="1115" y="43" fill="#8a877e" fontSize={11} fontWeight={400} textAnchor="middle">acquisition routes</text>
          <path d="M1005 72 H975 M1005 115 H975 M1005 158 H975 M975 72 V158"
            fill="none" stroke="#8a877e" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round" />
          <path d="M975 115 H951" fill="none" stroke="#8a877e" strokeWidth={1.7} strokeLinecap="round"
            markerEnd="url(#faq-paths-source-arrow)" />
          <rect x="1005" y="54" width="220" height="36" fill="#ffffff" stroke="#d9d7cf" strokeWidth={1.3} />
          <text x="1115" y="72" fill="#1a1a1a" fontSize={13} textAnchor="middle" dominantBaseline="middle">OpenSea</text>
          <rect x="1005" y="97" width="220" height="36" fill="#ffffff" stroke="#d9d7cf" strokeWidth={1.3} />
          <text x="1115" y="115" fill="#1a1a1a" fontSize={13} textAnchor="middle" dominantBaseline="middle">CreditStrategy</text>
          <rect x="1005" y="140" width="220" height="36" fill="#ffffff" stroke="#d9d7cf" strokeWidth={1.3} />
          <text x="1115" y="158" fill="#1a1a1a" fontSize={13} textAnchor="middle" dominantBaseline="middle">direct sales</text>
        </g>
        <g className="faq-paths-box faq-paths-credit-box">
          <rect x="245" y="233" width="270" height="74" fill="#f6f5f0" stroke="#00a3e0" strokeWidth={2} />
          <text x="380" y="270" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">individual Credit sale</text>
        </g>
        <g className="faq-paths-box faq-paths-statement-box">
          <rect x="605" y="233" width="341" height="74" fill="#f6f5f0" stroke="#e8c000" strokeWidth={2} />
          <text x="775" y="261" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">80 Credits become</text>
          <text x="775" y="284" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">one Statement</text>
        </g>
        <g className="faq-paths-box faq-paths-balance-box">
          <rect x="995" y="233" width="294" height="74" fill="#f6f5f0" stroke="#976ba9" strokeWidth={2} />
          <text x="1142" y="257" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">redeem for $BALANCE</text>
          <text x="1142" y="281" className="faq-paths-small" fill="#6e6c64" fontSize={12} fontWeight={400} textAnchor="middle" dominantBaseline="middle">if unsold after an hour</text>
        </g>
        <g className="faq-paths-box faq-paths-balance-box">
          <rect x="995" y="403" width="294" height="73" fill="#f6f5f0" stroke="#976ba9" strokeWidth={2} />
          <text x="1142" y="428" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">buy more Credits</text>
          <text x="1142" y="453" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">with $BALANCE (exchange)</text>
        </g>
        <g className="faq-paths-box faq-paths-future-box">
          <rect x="995" y="527" width="294" height="62" fill="#f6f5f0" stroke="#8a877e" strokeWidth={1.7} strokeDasharray="6 5" />
          <text x="1142" y="550" fill="#6e6c64" fontSize={14} fontWeight={400} textAnchor="middle" dominantBaseline="middle">future: burn $CC to redeem</text>
          <text x="1142" y="571" className="faq-paths-small" fill="#8a877e" fontSize={12} fontWeight={400} textAnchor="middle" dominantBaseline="middle">a share of the claim reserve · not active</text>
        </g>
        <g className="faq-paths-box faq-paths-outcome-box">
          <rect x="260" y="403" width="686" height="73" fill="#f6f5f0" stroke="#d9d7cf" strokeWidth={1.7} />
          <text x="603" y="428" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">NFT sales return ETH to the buying pot</text>
          <text x="603" y="453" fill="#1a1a1a" fontSize={15} fontWeight={400} textAnchor="middle" dominantBaseline="middle">resale gains above cost fund CC buybacks</text>
        </g>
        <g className="faq-paths-annotations" aria-hidden="true">
          <text x="104" y="302" fill="#e5007e" fontSize={12} fontWeight={400} textAnchor="middle" dominantBaseline="middle">ETH</text>
          <text x="104" y="320" fill="#e5007e" fontSize={12} fontWeight={400} textAnchor="middle" dominantBaseline="middle">cycles back</text>
          <text x="813" y="355" fill="#e5007e" fontSize={12} fontWeight={400} textAnchor="middle" dominantBaseline="middle">ETH sale</text>
          <text x="1085" y="366" className="faq-paths-balance-caption" fill="#976ba9" fontSize={12} fontWeight={400} textAnchor="middle" dominantBaseline="middle">$BALANCE path</text>
          <text x="1210" y="503" fill="#8a877e" fontSize={11} fontWeight={400} textAnchor="start" dominantBaseline="middle">10% held as</text>
          <text x="1210" y="517" fill="#8a877e" fontSize={11} fontWeight={400} textAnchor="start" dominantBaseline="middle">claim reserve</text>
        </g>
      </svg>
    </div>
  );
}

const allocations = [
  { title: "buying pot", percent: "97%", className: "pot", width: "97%" },
  { title: "artist", percent: "2.5%", className: "artist", width: "2.5%" },
  { title: "operator", percent: "0.5%", className: "operator", width: "0.5%" },
];

function SaleAllocation() {
  return (
    <div className="faq-allocation">
      <div className="faq-allocation-bar" role="img" aria-label="100 ETH Statement sale: 97 ETH to the buying pot, 2.5 ETH to the artist and 0.5 ETH to the operator">
        {allocations.map((part) => (
          <div key={part.className} className={"faq-allocation-segment " + part.className} style={{ width: part.width }} />
        ))}
      </div>
      <div className="faq-allocation-legend">
        {allocations.map((part) => (
          <div key={part.className} className="faq-allocation-item">
            <i className={"faq-allocation-dot " + part.className} />
            <span>{part.title}</span>
            <b>{part.percent}</b>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function Faq() {
  return (
    <main className="faq-page">
      <header className="faq-hero">
        <span className="faq-eyebrow">cc / start here</span>
        <h1>credits, on repeat.</h1>
        <p>
          $CC trading supports a standing buyer for Jack Butcher’s Credits, with a second bid in $BALANCE. inventory
          moves through resale, composition and conversion, and each round helps finance the next.
        </p>
      </header>

      <section className="faq-origin" aria-labelledby="faq-origin-title">
        <div>
          <span className="faq-section-num">01 / the source</span>
          <h2 id="faq-origin-title">before CC, there were Credits</h2>
        </div>
        <div className="faq-origin-prose">
          <p>
            <a href="https://jack.art/credits/" target="_blank" rel="noreferrer">Credits</a> is an artwork by
            Jack Butcher built from $8 payments through X Money. each eligible payment becomes a unique artwork
            using the transaction ID and timestamp. the original collection has 122,154 Credits.
          </p>
          <p>
            each Credit has a rarity score from 80 to 800. that rating reflects its visual traits, not its price.
            burning 80 Credits creates a <a href="https://jack.art/credits/" target="_blank" rel="noreferrer">Statement</a>.
            CC uses those existing rules as the basis for its acquisition engine.
          </p>
          <p className="faq-links">
            <a href="https://jack.art/credits/" target="_blank" rel="noreferrer">explore Credits ↗</a>
            <a href="https://jack.art/credits/rating" target="_blank" rel="noreferrer">how ratings work ↗</a>
          </p>
        </div>
      </section>

      <section className="faq-visuals" aria-labelledby="faq-mechanics-title">
        <div className="faq-visuals-heading">
          <span className="faq-section-num">02 / mechanics</span>
          <h2 id="faq-mechanics-title">built for movement</h2>
        </div>
        <div className="faq-visual-grid">
          <article className="faq-visual-card faq-visual-card-wide">
            <div className="faq-visual-copy">
              <h3>built around credits</h3>
              <p>creditcycle acquires Credits from holders, CreditStrategy and OpenSea, for ETH or $BALANCE. acquired Credits can be resold or composed into Statements. ETH sales replenish the pot; unsold Statements convert into $BALANCE that buys more Credits. $CC trading fees add new buying power. burning $CC for a share of the claim reserve is a future path, not yet active.</p>
            </div>
            <InventoryPaths />
            <small>both sale routes still depend on buyers, and their price floors can leave inventory unsold.</small>
          </article>
          <article className="faq-visual-card">
            <div className="faq-visual-copy">
              <h3>the bid moves</h3>
              <p>the ETH bid sits at 100% of a Credit&apos;s $BALANCE value, which moves with the $BALANCE price. a purchase drops it toward 90%, then it recovers.</p>
            </div>
            <BidIllustration />
            <small>illustrative only. not a quote or price forecast.</small>
          </article>
          <article className="faq-visual-card">
            <div className="faq-visual-copy">
              <h3>one Statement sale</h3>
              <p>how the proceeds of a 100 ETH Statement sale are allocated at the configured settings.</p>
            </div>
            <SaleAllocation />
            <small>sale allocations can be changed by the operator.</small>
          </article>
        </div>
      </section>

      <section className="faq-questions" aria-labelledby="faq-questions-title">
        <div className="faq-question-heading">
          <span className="faq-section-num">03 / questions</span>
          <h2 id="faq-questions-title">good to know</h2>
          <p>the parts that behave differently from a typical NFT collection or coin.</p>
        </div>
        <div className="faq-question-list">
          {questions.map(({ question, answer }, index) => (
            <details key={question} className="faq-question">
              <summary>
                <span className="faq-question-index">{String(index + 1).padStart(2, "0")}</span>
                <span>{question}</span>
                <span className="faq-question-toggle" aria-hidden="true">+</span>
              </summary>
              <div className="faq-answer">{answer}</div>
            </details>
          ))}
        </div>
      </section>

      <nav className="faq-more" aria-label="more information">
        <Link href="/">view the engine <span aria-hidden="true">↗</span></Link>
        <Link href="/docs">contract documentation <span aria-hidden="true">↗</span></Link>
      </nav>
    </main>
  );
}
