export const metadata = { title: "Risk disclosure — Blockroom" };

export default function RiskPage() {
  return (
    <div className="prose">
      <h1>Risk disclosure</h1>
      <p className="sub">Read this before using Blockroom. By connecting a wallet you confirm you understand these risks.</p>

      <h2>What Blockroom is — and isn&apos;t</h2>
      <ul>
        <li>
          Blockroom is non-custodial, open-source smart-contract software for negotiating and settling large trades of
          tokenized stocks. It is not a broker, exchange, investment adviser or fiduciary, and it does not hold your
          funds outside of the smart contracts you interact with.
        </li>
        <li>Nothing on this site is investment, legal or tax advice. You are solely responsible for your trading decisions.</li>
        <li>
          Blockroom is independent and is not affiliated with, endorsed by or sponsored by the issuers of any tokenized
          stock, the operators of the underlying blockchain, or any brokerage.
        </li>
      </ul>

      <h2>Tokenized stocks</h2>
      <ul>
        <li>
          Tokenized stocks are issued by third parties. Their value depends on the issuer, its custody arrangements and
          its legal terms. They may not carry the rights of the underlying shares (e.g. voting).
        </li>
        <li>
          Corporate actions (splits, dividends) are reflected through a token multiplier set by the issuer. Raw token
          amounts and share amounts can differ.
        </li>
        <li>Issuers or the network may restrict transfers for compliance reasons; a transfer can fail outside your control.</li>
        <li>Availability may be restricted in your jurisdiction. You must comply with the laws that apply to you.</li>
      </ul>

      <h2>Pricing and oracles</h2>
      <ul>
        <li>
          Price guards and midpoint execution use third-party oracle prices. Oracle prices can be delayed, stale, wrong
          or unavailable. The oracle updates on deviation and heartbeat, so the on-chain mid can lag the live market.
        </li>
        <li>
          The price guard only bounds how far a quote can be from the oracle mid; it does not guarantee a good price. A
          quote inside the band can still be worse than the market.
        </li>
        <li>Midpoint batches void automatically when the market is closed or the oracle is unhealthy.</li>
      </ul>

      <h2>RFQ and market makers</h2>
      <ul>
        <li>
          Quotes come from independent market makers. A maker may fail to deliver; in that case your funds are returned
          and you receive a penalty from the maker&apos;s bond, capped at the bond. The penalty may not cover your
          opportunity cost.
        </li>
        <li>
          The RFQ relay is off-chain infrastructure that can go offline or be slow. It cannot alter or forge signed
          quotes, but it sees your requests. Use &ldquo;two-way&rdquo; requests to hide your direction.
        </li>
      </ul>

      <h2>Midpoint (dark pool)</h2>
      <ul>
        <li>
          Orders are hidden only until they are revealed for settlement. Revealed orders, executions and deposits are
          public on-chain. The asset you commit to and the number of commitments in a batch are visible.
        </li>
        <li>
          Your order details are stored in your browser until you reveal. If you clear your browser data before
          revealing you lose the ability to reveal, and your commitment bond is forfeited.
        </li>
        <li>There is no guarantee of a fill; orders match only against opposing interest at the mid.</li>
      </ul>

      <h2>Smart-contract and operational risk</h2>
      <ul>
        <li>
          Smart contracts can contain bugs despite testing and review. Exploits can result in a total loss of funds.
        </li>
        <li>
          Administrative changes are delayed by a 48-hour timelock. A guardian can pause trading (but not move funds) in
          an emergency; pool withdrawals remain available while paused.
        </li>
        <li>
          Blockchain transactions are irreversible. Network congestion, sequencer downtime or wallet failures can delay
          or prevent transactions.
        </li>
      </ul>

      <h2>Project token</h2>
      <p>
        If a project token is enabled, staking it carries market and smart-contract risk, has an unstaking cooldown,
        and fee distributions are not guaranteed. The token is launched separately and is not issued by these contracts.
      </p>
    </div>
  );
}
