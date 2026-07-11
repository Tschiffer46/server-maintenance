FROM python:3.12-slim

# Elprishämtningen räknar lokala dygn — tidszonen måste vara svensk.
ENV TZ=Europe/Stockholm \
    PYTHONUNBUFFERED=1

# tzdata: korrekt lokal tid; sqlite3: säkra backuper + felsökning av energi.db
RUN apt-get update \
 && apt-get install -y --no-install-recommends tzdata sqlite3 \
 && ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime \
 && echo "$TZ" > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# app.py, index.html och energi.db monteras som volym (./app -> /app),
# så en ombyggd image rör aldrig databasen.
EXPOSE 8420
CMD ["python", "app.py"]
