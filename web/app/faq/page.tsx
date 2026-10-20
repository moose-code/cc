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
        a recurring market participant. $CC trading fees fund a standing bid for Credits. the engine acquires them
        by rating, offers individual Credits back to collectors, and assembles eligible groups of 80 into Statements.
        completed NFT sales return ETH to the buying pot and set aside ETH for future CC buybacks.
      </p>
    ),
  },
  {
    question: "is this just a system for buying and relisting NFTs?",
    answer: (
      <p>
        relisting is one path, but the engine is designed for continued turnover. an acquired Credit enters a sale
        window with a declining ask. after that window, unsold Credits can be composed into Statements that have their
        own descending sale prices. completed sales fund further acquisitions and CC buybacks. neither path requires
        a buyer to accept a permanently increasing markup, although each sale still has a floor.
      </p>
    ),
  },
  {
    question: "how is the bid calculated?",
    answer: (
      <p>
        each Credit has a rating assigned by the original Credits system. the engine quotes an ETH price per 100 rating
        points, then scales it to that Credit. the rate rises with time when the buying pot can fund another acquisition.
        buying a Credit pushes the rate down. higher rated Credits cost more and move the rate more. the rate, limits, and
        timing can be changed by the operator.
      </p>
    ),
  },
  {
    question: "what happens if Credit prices fall?",
    answer: (
      <p>
        the bid responds to actual acquisitions. each fill lowers its rate, and new $CC trading fees can replenish
        the buying pot even when older inventory has not sold. resale prices also decline over their windows, but
        they stop at floors tied to recorded cost and value. a deep market decline can leave Credits or Statements
        unsold, slowing capital recycling and CC buybacks. the system is designed to keep participating through
        changing markets, but continuous sales are never guaranteed.
      </p>
    ),
  },
  {
    question: "can i sell any Credit to the engine?",
    answer: (
      <p>
        an eligible Credit can be sold at its current quote, including as part of a batch, while the engine has enough
        available ETH. some of the pot is reserved for processing. buying can also be limited by a pause, spending rules,
        or a temporary return lock on Credits previously sold by the engine. a visible quote does not guarantee execution
        later in the block.
      </p>
    ),
  },
  {
    question: "is the CC bid a floor price for Credits?",
    answer: (
      <p>
        there is a public offer while the engine is funded and accepting Credits, but no guaranteed collection floor.
        the bid changes after acquisitions, stops climbing when funding is insufficient, and can be altered or paused by
        the operator. a Credit with more rating points receives a larger quote at the same rate.
      </p>
    ),
  },
  {
    question: "what happens to Credits CC buys?",
    answer: (
      <p>
        each acquired Credit enters the engine inventory and is offered for sale at a price that declines over a
        configurable window. if still held when its window has passed, it can be included in a group of 80 that is
        burned to mint a new Statement. anyone can trigger eligible composition.
      </p>
    ),
  },
  {
    question: "what happens when a Statement is made?",
    answer: (
      <p>
        the 80 original Credits are burned through Jack Butcher’s Statements contract, and the resulting Statement is
        held by CC. the engine offers it for ETH, initially above a reference based on its acquisition costs and rated
        value. its ask declines to a floor over time. the sale proceeds help finance the next cycle.
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
        acquisition engine and 0.69% goes to the artcoins protocol fee leg. engine income is booked into the ETH
        buying pot under the launch settings. these fees apply to trades in the CC pool, including buys and sells.
        the opening fee starts at 69% and declines to 6.9% over 69 minutes after pool launch. the trade panel displays
        the current fee during that period.
      </p>
    ),
  },
  {
    question: "how does the artist get paid?",
    answer: (
      <p>
        the engine pays a 2.5% artist royalty on top of what it pays for each Credit it acquires. the holder receives
        the full quoted amount when selling directly. a separate 2.5% artist allocation comes out of the price of
        every Credit or Statement the engine resells. these are CC engine payments to the designated artist recipient,
        separate from any fees an external marketplace may charge.
      </p>
    ),
  },
  {
    question: "what happens to ETH from a Statement sale?",
    answer: (
      <p>
        with the current configured split, 2.5% of the sale goes to the artist and 0.5% to the operator. of the remaining
        97%, one quarter is reserved for later CC buybacks and three quarters returns to the purchasing pot. the
        diagram above shows an example. individual Credit sales follow a different rule based on their recorded cost,
        so their buyback percentage varies.
      </p>
    ),
  },
  {
    question: "does every trade or NFT sale immediately burn CC?",
    answer: (
      <p>
        no. trading fees first support the acquisition pot. ETH designated for buybacks accumulates when NFTs sell,
        then a permitted onchain call swaps that ETH for CC and burns the purchased coins. the swap must actually
        succeed. the amount burned depends on market conditions, available funds, and execution.
      </p>
    ),
  },
  {
    question: "how was CC distributed at launch?",
    answer: (
      <p>
        the launch configuration specifies a supply of one billion CC. it sends the supply to the initial ETH trading
        liquidity through the artcoins factory and its locker, with no separate presale, team token allocation,
        airdrop, or token distribution extension configured. holding CC does not grant a claim on the engine’s ETH or NFTs.
      </p>
    ),
  },
  {
    question: "who controls the engine?",
    answer: (
      <p>
        CC is autonomous in the sense that its public rules execute onchain and anyone can use its permitted actions.
        the operator still controls important settings, including the bid, sale rules, payment percentages, pauses,
        and some contract replacements. there is no delay on those setting changes. the code supports one way locks
        for some permissions, but do not assume every permission has been locked. current settings can be inspected
        onchain.
      </p>
    ),
  },
  {
    question: "does CC need BALANCE to work?",
    answer: (
      <p>
        no. the initial cycle uses ETH to buy Credits and sell Credits and Statements. separate contract features can
        support the BALANCE ecosystem later, but they depend on external deployment and operator activation. CC’s
        ETH acquisition and resale cycle can operate without them.
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

function BidIllustration() {
  return (
    <svg className="faq-bid-drawing" viewBox="0 0 480 174" role="img" aria-label="illustration: a funded bid climbs with time, falls after a purchase, then can climb again">
      <line x1="14" y1="145" x2="466" y2="145" className="faq-axis" />
      <line x1="14" y1="16" x2="14" y2="145" className="faq-axis" />
      <path className="faq-bid-path" d="M24 134 L83 114 L151 78 L192 48 L195 117 L245 103 L297 76 L347 52 L350 115 L408 96 L456 67" />
      <circle cx="195" cy="117" r="5" className="faq-drop-dot" />
      <circle cx="350" cy="115" r="5" className="faq-drop-dot" />
      <text x="195" y="137" textAnchor="middle" className="faq-bid-label">buy</text>
      <text x="350" y="135" textAnchor="middle" className="faq-bid-label">buy</text>
      <text x="102" y="56" className="faq-bid-label">funded climb</text>
      <text x="268" y="35" className="faq-bid-label">funded climb</text>
      <text x="20" y="165" className="faq-bid-label">time →</text>
    </svg>
  );
}

const allocations = [
  { title: "buying pot", percent: "72.75%", className: "pot", width: "72.75%" },
  { title: "CC buyback", percent: "24.25%", className: "buyback", width: "24.25%" },
  { title: "artist", percent: "2.5%", className: "artist", width: "2.5%" },
  { title: "operator", percent: "0.5%", className: "operator", width: "0.5%" },
];

function SaleAllocation() {
  return (
    <div className="faq-allocation">
      <div className="faq-allocation-bar" role="img" aria-label="100 ETH Statement sale: 72.75 ETH to the buying pot, 24.25 ETH to future CC buybacks, 2.5 ETH to the artist and 0.5 ETH to the operator">
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
          $CC trading supports a standing buyer for Jack Butcher’s Credits. acquisitions change its bid, inventory
          moves through resale or composition, and successful sales help finance the next round.
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
          <h2 id="faq-mechanics-title">two things worth seeing</h2>
        </div>
        <div className="faq-visual-grid">
          <article className="faq-visual-card">
            <div className="faq-visual-copy">
              <h3>the bid moves</h3>
              <p>the ETH bid climbs while funded, then drops when the engine acquires a Credit.</p>
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
            <small>sale allocations can be changed by the operator. buybacks happen later.</small>
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
