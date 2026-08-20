-- Allow anon users to look up accounts by email during signup
CREATE POLICY "Anon read access on accounts" ON accounts
  FOR SELECT TO anon USING (true);
