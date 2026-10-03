"""Seed a demo Clocktopus database (schema already created by the app).
usage: seed.py PATH.sqlite"""
import sqlite3, uuid, sys
from datetime import datetime, timedelta
db = sqlite3.connect(sys.argv[1])
db.execute("delete from timeEntry"); db.execute("delete from provisionalBlock"); db.execute("delete from observation")
def ts(d, hm): h, m = map(int, hm.split(':')); return datetime(d.year, d.month, d.day, h, m).timestamp()
# A full Mon–Fri of the current ISO week, so the week chart and grid are busy
# whatever day you shoot on.
monday = datetime.now().date() - timedelta(days=datetime.now().weekday())
weekdays = [datetime.combine(monday + timedelta(days=i), datetime.min.time()) for i in range(5)]
days = dict(zip(weekdays, [
 [('initech','08:30','11:45'),('meetings','11:45','12:30'),('globex','13:15','16:30'),('nautilus','16:30','17:15')],
 [('initech','08:45','12:00'),('globex','12:45','15:30'),('meetings','15:30','16:00'),('initech','16:00','17:30')],
 [('nautilus','09:00','12:15'),('meetings','13:00','13:30'),('initech','13:30','17:00')],
 [('initech','08:30','10:00'),('meetings','10:00','10:45'),('globex','10:45','12:30'),('initech','13:15','16:45'),('side-quest','20:00','21:30')],
 [('globex','08:30','11:30'),('meetings','11:30','12:00'),('initech','12:45','15:45')],
]))
for day, entries in days.items():
    d = day
    for pid, s, e in entries:
        db.execute("insert into timeEntry (id, projectId, start, \"end\", source, note, exportedAt) values (?,?,?,?,?,?,?)",
                   (str(uuid.uuid4()).upper(), pid, ts(d, s), ts(d, e), 'manual', None, None))
# a running timer, so the menubar shows a live clock
now = datetime.now()
db.execute("insert into timeEntry (id, projectId, start, \"end\", source, note, exportedAt) values (?,?,?,?,?,?,?)",
           (str(uuid.uuid4()).upper(), 'initech', (now - timedelta(minutes=41)).timestamp(), None, 'backfill', None, None))
# ghost blocks on the Friday afternoon (the Day screenshot)
d = weekdays[4]
blocks = [
 ('nautilus', '16:00', '17:10', 0.9, 'terminal in ~/src/nautilus-api · AI tool in ~/src/nautilus-api · browser github.com', 'aiTool,browser,terminal'),
 (None, '17:20', '17:45', 0.4, 'browser docs.example.com · Google Chrome', 'browser'),
]
for pid, s, e, c, ev, sig in blocks:
    db.execute("insert into provisionalBlock (id, guessedProjectId, start, \"end\", confidence, evidence, status, signals) values (?,?,?,?,?,?,?,?)",
               (str(uuid.uuid4()).upper(), pid, ts(d, s), ts(d, e), c, ev, 'pending', sig))
db.execute("insert into observation (timestamp, payload) values (?, ?)",
           (now.timestamp(), '{"timestamp":%f,"dirs":[],"idleSeconds":0}' % (now.timestamp() - 978307200)))
db.commit(); print("seeded", db.execute("select count(*) from timeEntry").fetchone()[0], "entries")
