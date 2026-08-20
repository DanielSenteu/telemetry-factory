import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Anthropic from "npm:@anthropic-ai/sdk";

const EXTRACTION_PROMPT = `You are an invoice data extraction assistant. Analyze this invoice image and extract the following structured data.

Return ONLY valid JSON with this exact structure:
{
  "vendor_name": "string or null",
  "invoice_number": "string or null",
  "invoice_date": "YYYY-MM-DD or null",
  "total_amount": number or null,
  "vat_amount": number or null,
  "line_items": [
    {
      "description": "string",
      "quantity": number or null,
      "unit_price": number or null,
      "total_price": number or null
    }
  ]
}

Rules:
- If only total_price and quantity are available, calculate unit_price = total_price / quantity
- If only unit_price and quantity are available, calculate total_price = unit_price * quantity
- If only a total is shown with no quantity breakdown, set quantity to 1 and unit_price = total_price
- vat_amount is the tax/VAT shown on the invoice (often labelled "VAT", "VAT 16%", or "Tax"); null if none is shown
- line_items prices should be the NET amounts (before VAT); total_amount is the GROSS (net lines + vat_amount)
- All prices should be numbers (no currency symbols)
- Dates should be in YYYY-MM-DD format
- Return ONLY the JSON, no markdown fences or extra text`;

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const { storage_path, file_name } = await req.json();

    if (!storage_path) {
      return new Response(
        JSON.stringify({ error: "storage_path is required" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    // Create Supabase client with service role (auto-injected in Edge Functions)
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Download file from Storage
    const { data: fileData, error: downloadError } = await supabase.storage
      .from("invoices")
      .download(storage_path);

    if (downloadError || !fileData) {
      return new Response(
        JSON.stringify({
          error: `Failed to download file: ${downloadError?.message}`,
        }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }

    // Convert to base64 — chunked to avoid call-stack overflow on large files.
    // btoa(String.fromCharCode(...bigArray)) crashes for files > ~1 MB because
    // the spread passes every byte as a separate argument, exhausting the stack.
    const arrayBuffer = await fileData.arrayBuffer();
    const uint8 = new Uint8Array(arrayBuffer);
    let binary = "";
    const CHUNK = 8192;
    for (let i = 0; i < uint8.length; i += CHUNK) {
      binary += String.fromCharCode(...uint8.subarray(i, i + CHUNK));
    }
    const base64 = btoa(binary);

    // Determine media type from file name
    const ext = (file_name || storage_path).split(".").pop()?.toLowerCase();
    const mediaTypeMap: Record<string, string> = {
      png: "image/png",
      jpg: "image/jpeg",
      jpeg: "image/jpeg",
      gif: "image/gif",
      webp: "image/webp",
      pdf: "application/pdf",
    };
    const mediaType = mediaTypeMap[ext || ""] || "image/png";

    // Build content block (document for PDF, image for everything else)
    const contentBlock =
      mediaType === "application/pdf"
        ? {
            type: "document" as const,
            source: {
              type: "base64" as const,
              media_type: mediaType as "application/pdf",
              data: base64,
            },
          }
        : {
            type: "image" as const,
            source: {
              type: "base64" as const,
              media_type: mediaType as
                | "image/png"
                | "image/jpeg"
                | "image/gif"
                | "image/webp",
              data: base64,
            },
          };

    // Call Claude
    const anthropic = new Anthropic({
      apiKey: Deno.env.get("ANTHROPIC_API_KEY")!,
    });

    const response = await anthropic.messages.create({
      model: "claude-haiku-4-5-20251001",
      max_tokens: 2048,
      messages: [
        {
          role: "user",
          content: [contentBlock, { type: "text", text: EXTRACTION_PROMPT }],
        },
      ],
    });

    // Parse response — strip any markdown fences then extract the first JSON object.
    let text = (response.content[0] as { type: "text"; text: string }).text.trim();
    text = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
    // Find the outermost { … } in case Claude adds commentary before/after.
    const jsonStart = text.indexOf("{");
    const jsonEnd = text.lastIndexOf("}");
    if (jsonStart === -1 || jsonEnd === -1) {
      throw new Error(`Claude returned no JSON object. Raw response: ${text.slice(0, 200)}`);
    }
    const extracted = JSON.parse(text.slice(jsonStart, jsonEnd + 1));

    // Attach metadata
    extracted.file_name = file_name;
    extracted.storage_path = storage_path;

    return new Response(
      JSON.stringify({ success: true, data: extracted }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  } catch (err) {
    console.error("process-invoice error:", err);
    return new Response(
      JSON.stringify({
        error: err instanceof Error ? err.message : "Failed to process invoice",
      }),
      {
        status: 500,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  }
});
