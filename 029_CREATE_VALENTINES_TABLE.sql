CREATE TABLE valentinesmessages (
  id INT PRIMARY KEY,
  sender INT NOT NULL,
  recipient INT NOT NULL,
  message TEXT NOT NULL,
  background VARCHAR(50) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  verified_at TIMESTAMP DEFAULT NULL,
  verified_by INT DEFAULT NULL,
  FOREIGN KEY (sender) REFERENCES users(id),
  FOREIGN KEY (recipient) REFERENCES users(id),
  FOREIGN KEY (verified_by) REFERENCES users(id)
);

ALTER TYPE site_perms ADD VALUE 'VALENTINES';
