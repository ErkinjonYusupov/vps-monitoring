import os, json, time
from app import metrics
m=metrics()
ram=float(os.getenv('ALERT_RAM_PCT','85'))
disk=float(os.getenv('ALERT_DISK_PCT','85'))
load=float(os.getenv('ALERT_LOAD_PER_CORE','2.0'))
issues=[]
if m['ram']['pct']>=ram: issues.append(f"RAM {m['ram']['pct']}%")
if m['disk']['pct']>=disk: issues.append(f"Disk {m['disk']['pct']}%")
if m['cpu']['load_per_core']>=load: issues.append(f"Load/core {m['cpu']['load_per_core']}")
if issues:
 print('ALERT: VPS monitor — ' + ', '.join(issues))
 print(json.dumps({k:m[k] for k in ['host','cpu','ram','disk']}, indent=2))
else:
 print('OK')
