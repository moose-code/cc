// Route content between the header and the footer. A template remounts on every navigation, so each new page fades in
// while the header and footer stay put (web/design/README.md, "loading and motion").
export default function Template({ children }: { children: React.ReactNode }) {
  return <div className="route">{children}</div>;
}
