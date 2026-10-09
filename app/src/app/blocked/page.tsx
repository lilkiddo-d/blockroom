export const metadata = { title: "Unavailable — Blockroom" };

export default function BlockedPage() {
  return (
    <div className="prose">
      <h1>Not available in your region</h1>
      <p>
        This interface is not available in your jurisdiction. The underlying smart contracts are public software;
        using them may be restricted where you live. Please make sure you comply with the laws that apply to you.
      </p>
    </div>
  );
}
