export type AccountRole = "admin" | "worker";

export type ModuleKey = "invoicing" | "attendance" | "integrations";

export interface Organization {
  id: number;
  name: string;
  created_at: string;
}

export interface Account {
  id: number;
  org_id: number;
  email: string;
  role: AccountRole;
  user_id: string | null;
  created_at: string;
}

export interface OrgModule {
  id: number;
  org_id: number;
  module_key: ModuleKey;
  enabled: boolean;
}

export interface Workplace {
  id: number;
  org_id: number;
  name: string;
  latitude: number;
  longitude: number;
  clock_in_radius: number;
  clock_out_radius: number;
  created_at: string;
}

export interface Worker {
  id: number;
  org_id: number;
  name: string;
  email: string;
  phone: string | null;
  workplace_id: number | null;
  is_active: boolean;
  user_id: string | null;
  created_at: string;
}

export interface TimesheetEntry {
  id: number;
  worker_id: number;
  workplace_id: number | null;
  clock_in: string;
  clock_out: string | null;
  clock_in_lat: number | null;
  clock_in_lng: number | null;
  clock_out_lat: number | null;
  clock_out_lng: number | null;
  created_at: string;
}

export interface Invoice {
  id: number;
  org_id: number;
  vendor_name: string | null;
  invoice_number: string | null;
  invoice_date: string | null;
  total_amount: number | null;
  file_name: string | null;
  storage_path: string | null;
  created_at: string;
}

export interface LineItem {
  id: number;
  invoice_id: number;
  description: string;
  quantity: number | null;
  unit_price: number | null;
  total_price: number | null;
}
