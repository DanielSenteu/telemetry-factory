// Ported from v1 invoiceService.js. Photo → storage (org-scoped folder so
// storage RLS walls tenants off) → process-invoice edge function (AI reads it)
// → review → confirm_invoice RPC (records the document + posts 'purchase'
// stock movements for mapped lines; unmapped lines are recorded, not stocked).

import { supabase } from "@/lib/supabase/browser";

export type ExtractedLine = {
  description: string;
  quantity: number;
  unit_price: number;
  total_price: number;
};

export type ExtractedInvoice = {
  vendor_name: string | null;
  invoice_number: string | null;
  invoice_date: string | null;
  total_amount: number | null;
  vat_amount?: number | null;
  line_items: ExtractedLine[];
  file_name?: string;
  storage_path?: string;
};

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

/** Defensive shaping of whatever the AI returned — never trust extraction blindly. */
function shapeExtracted(raw: Record<string, unknown>): ExtractedInvoice {
  const lines = Array.isArray(raw.line_items) ? raw.line_items : [];
  return {
    vendor_name: typeof raw.vendor_name === "string" ? raw.vendor_name : null,
    invoice_number: typeof raw.invoice_number === "string" ? raw.invoice_number : null,
    invoice_date: typeof raw.invoice_date === "string" ? raw.invoice_date : null,
    total_amount: raw.total_amount == null ? null : num(raw.total_amount),
    vat_amount: raw.vat_amount == null ? 0 : num(raw.vat_amount),
    line_items: lines.map((l) => {
      const r = l as Record<string, unknown>;
      return {
        description: typeof r.description === "string" ? r.description : "",
        quantity: num(r.quantity ?? 1) || 1,
        unit_price: num(r.unit_price),
        total_price: num(r.total_price ?? num(r.quantity ?? 1) * num(r.unit_price)),
      };
    }),
  };
}

export async function uploadAndExtract(orgId: number, file: File): Promise<ExtractedInvoice> {
  const safeName = file.name.replace(/[^\w.-]+/g, "_");
  const storagePath = `${orgId}/${Date.now()}-${safeName}`;

  const { error: uploadError } = await supabase.storage.from("invoices").upload(storagePath, file);
  if (uploadError) throw new Error(uploadError.message);

  const { data, error: fnError } = await supabase.functions.invoke("process-invoice", {
    body: { storage_path: storagePath, file_name: file.name },
  });
  if (fnError) throw new Error(`Could not read the invoice: ${data?.error || fnError.message}`);
  if (!data?.success) throw new Error(data?.error || "Could not read the invoice");

  return { ...shapeExtracted(data.data), file_name: file.name, storage_path: storagePath };
}

export async function confirmInvoice(
  orgId: number,
  invoice: ExtractedInvoice,
  lineItems: Array<ExtractedLine & { product_id: number | null }>,
) {
  const { data, error } = await supabase.rpc("confirm_invoice", {
    p_org_id: orgId,
    p_vendor_name: invoice.vendor_name || null,
    p_invoice_number: invoice.invoice_number || null,
    p_invoice_date: invoice.invoice_date || null,
    p_total_amount: invoice.total_amount ?? null,
    p_file_name: invoice.file_name || null,
    p_storage_path: invoice.storage_path || null,
    p_line_items: lineItems,
    p_vat_amount: invoice.vat_amount ?? 0,
  });
  if (error) throw new Error(error.message);
  return data as number;
}

export type ProductAlias = { vendor_name: string | null; raw_text: string; product_id: number };

export async function listProductAliases(orgId: number): Promise<ProductAlias[]> {
  const { data, error } = await supabase
    .from("product_aliases")
    .select("vendor_name, raw_text, product_id")
    .eq("org_id", orgId);
  if (error) throw new Error(error.message);
  return data || [];
}
