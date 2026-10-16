import { ogContentType, ogImage, ogSize } from "@/lib/og";
import { getToken } from "@/lib/meta";

export const alt = "statement";
export const size = ogSize;
export const contentType = ogContentType;

export default async function Image({ params }: { params: { id: string } }) {
  const id = Number(params.id);
  const t = Number.isInteger(id) && id >= 0 ? await getToken("statement", id, true) : null;
  return ogImage({
    title: `statement ${params.id}`,
    line: [t?.format, t?.rating ? `rating ${t.rating}` : undefined].filter(Boolean).join(" · ") || "a statement of the Credit Cycle.",
    stat: t?.state,
    art: t?.art,
  });
}
