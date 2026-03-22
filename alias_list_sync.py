#!/usr/bin/env python3
import os
import json
import mysql.connector

MYSQL_HOST = os.getenv("MAILCOW_DBHOST")
MYSQL_USER = os.getenv("MAILCOW_DBUSER")
MYSQL_PASS = os.getenv("MAILCOW_DBPASS")
MYSQL_DB   = os.getenv("MAILCOW_DBNAME")

OUTPUT = "/etc/rspamd/list_policies.json"

db = mysql.connector.connect(
    host=MYSQL_HOST,
    user=MYSQL_USER,
    password=MYSQL_PASS,
    database=MYSQL_DB
)

cur = db.cursor(dictionary=True)

cur.execute("""
SELECT address, goto, private_comment, public_comment
FROM alias
WHERE islist = 1 AND active = 1
""")

policies = {}

for row in cur.fetchall():
    policies[row["address"]] = {
        "policy": (row["private_comment"] or "public").lower(),
        "members": list(set([x.strip() for x in (row["goto"] or "").split(",") if x.strip()])),
        "moderators": list(set([x.strip() for x in (row["public_comment"] or "").split(",") if x.strip()]))
    }

with open(OUTPUT, "w") as f:
    json.dump(policies, f)

cur.close()
db.close()
