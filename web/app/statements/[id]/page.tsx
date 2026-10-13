import { notFound } from "next/navigation";
import { LiveStatement } from "@/components/StatementLive";

export default function StatementDetail({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  if (!Number.isInteger(id) || id < 0) notFound();
  return <LiveStatement id={id} />;
}
