ALTER TABLE memberships
ADD CONSTRAINT delete_cascade FOREIGN KEY (organization_id) REFERENCES organizations(id)
  ON DELETE CASCADE;

ALTER TABLE organizationedits
ADD CONSTRAINT delete_cascade FOREIGN KEY (organization_id) REFERENCES organizations(id)
  ON DELETE CASCADE;

ALTER TABLE meetings
ADD CONSTRAINT delete_cascade FOREIGN KEY (organization_id) REFERENCES organizations(id)
  ON DELETE CASCADE;

ALTER TABLE posts
ADD CONSTRAINT delete_cascade FOREIGN KEY (organization_id) REFERENCES organizations(id)
  ON DELETE CASCADE;

ALTER TABLE strikes
ADD CONSTRAINT delete_cascade FOREIGN KEY (organization_id) REFERENCES organizations(id)
  ON DELETE CASCADE;
