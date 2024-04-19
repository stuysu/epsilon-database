-- RLS for buckets in supabase storage
CREATE POLICY "Allow verified users to upload files"
ON storage.objects 
FOR INSERT 
TO authenticated 
WITH CHECK (
    EXISTS (
      SELECT 1
      FROM users AS u
      WHERE (u.email = (auth.jwt() ->> 'email'))
    )
    AND (
      -- restrict buckets
      bucket_id = 'public-files'
    )
);
