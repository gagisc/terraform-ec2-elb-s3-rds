#!/bin/bash
set -xe

# Install dependencies
yum update -y
yum install -y python3 python3-pip

pip3 install flask boto3 psycopg2-binary

cat > /opt/app.py << 'PYEOF'
import os
import json
from flask import Flask, request, render_template_string
import boto3
import psycopg2

APP_DATA_BUCKET = os.environ.get("APP_DATA_BUCKET")
DB_ENDPOINT = os.environ.get("DB_ENDPOINT")
DB_NAME = os.environ.get("DB_NAME")
DB_USERNAME = os.environ.get("DB_USERNAME")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
SERVER_MESSAGE = os.environ.get("SERVER_MESSAGE", "Hello World")

s3 = boto3.client("s3")

app = Flask(__name__)

HTML = """
<!doctype html>
<title>Contacts App</title>
<h1>{{ server_message }}</h1>

<h2>Add contact (S3)</h2>
<form method="post" action="/add_s3">
  Name: <input name="name"><br>
  Phone: <input name="phone"><br>
  <input type="submit" value="Save to S3">
</form>

<h2>Search contacts (S3)</h2>
<form method="get" action="/search_s3">
  Name: <input name="name"><br>
  <input type="submit" value="Search in S3">
</form>

{% if s3_result is not none %}
  <p>S3 result: {{ s3_result }}</p>
{% endif %}

<hr>

<h2>Add contact (RDS)</h2>
<form method="post" action="/add_rds">
  Name: <input name="name"><br>
  Phone: <input name="phone"><br>
  <input type="submit" value="Save to RDS">
</form>

<h2>Search contacts (RDS)</h2>
<form method="get" action="/search_rds">
  Name: <input name="name"><br>
  <input type="submit" value="Search in RDS">
</form>

{% if rds_result is not none %}
  <p>RDS result: {{ rds_result }}</p>
{% endif %}
"""

S3_KEY = "contacts.json"


def load_s3_contacts():
    try:
        resp = s3.get_object(Bucket=APP_DATA_BUCKET, Key=S3_KEY)
        return json.loads(resp["Body"].read().decode("utf-8"))
    except Exception:
        return {}


def save_s3_contacts(data):
    s3.put_object(Bucket=APP_DATA_BUCKET, Key=S3_KEY, Body=json.dumps(data).encode("utf-8"))


def get_db_conn():
    return psycopg2.connect(
        host=DB_ENDPOINT,
        dbname=DB_NAME,
        user=DB_USERNAME,
        password=DB_PASSWORD,
    )


def ensure_rds_table():
    conn = get_db_conn()
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS contacts (
            name text primary key,
            phone text
        );
        """
    )
    cur.close()
    conn.close()


@app.route("/", methods=["GET"])
def index():
    return render_template_string(HTML, server_message=SERVER_MESSAGE, s3_result=None, rds_result=None)


@app.route("/add_s3", methods=["POST"])
def add_s3():
    name = request.form.get("name")
    phone = request.form.get("phone")
    data = load_s3_contacts()
    data[name] = phone
    save_s3_contacts(data)
    return render_template_string(HTML, server_message=SERVER_MESSAGE, s3_result=f"Saved {name}", rds_result=None)


@app.route("/search_s3", methods=["GET"])
def search_s3():
    name = request.args.get("name")
    data = load_s3_contacts()
    phone = data.get(name)
    result = f"{name}: {phone}" if phone else "Not found"
    return render_template_string(HTML, server_message=SERVER_MESSAGE, s3_result=result, rds_result=None)


@app.route("/add_rds", methods=["POST"])
def add_rds():
    name = request.form.get("name")
    phone = request.form.get("phone")
    ensure_rds_table()
    conn = get_db_conn()
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("INSERT INTO contacts(name, phone) VALUES(%s, %s) ON CONFLICT (name) DO UPDATE SET phone = EXCLUDED.phone", (name, phone))
    cur.close()
    conn.close()
    return render_template_string(HTML, server_message=SERVER_MESSAGE, s3_result=None, rds_result=f"Saved {name}")


@app.route("/search_rds", methods=["GET"])
def search_rds():
    name = request.args.get("name")
    ensure_rds_table()
    conn = get_db_conn()
    cur = conn.cursor()
    cur.execute("SELECT phone FROM contacts WHERE name = %s", (name,))
    row = cur.fetchone()
    cur.close()
    conn.close()
    if row:
        result = f"{name}: {row[0]}"
    else:
        result = "Not found"
    return render_template_string(HTML, server_message=SERVER_MESSAGE, s3_result=None, rds_result=result)


if __name__ == "__main__":
    ensure_rds_table()
    app.run(host="0.0.0.0", port=80)
PYEOF

cat > /etc/systemd/system/app.service << 'SEOF'
[Unit]
Description=Contacts Flask App
After=network.target

[Service]
Type=simple
Environment=APP_DATA_BUCKET=${app_data_bucket}
Environment=DB_ENDPOINT=${db_endpoint}
Environment=DB_NAME=${db_name}
Environment=DB_USERNAME=${db_username}
Environment=DB_PASSWORD=${db_password}
Environment=SERVER_MESSAGE=${SERVER_MESSAGE}
ExecStart=/usr/bin/python3 /opt/app.py
Restart=always

[Install]
WantedBy=multi-user.target
SEOF

systemctl daemon-reload
systemctl enable app.service
systemctl start app.service
