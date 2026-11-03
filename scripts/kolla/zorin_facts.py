"""Normaliza facts do Ansible coletados no Zorin OS para o Kolla tratar como Ubuntu Noble.

Uso: python3 zorin_facts.py <saida de `ansible -m setup --tree`>/localhost <arquivo de saida>
Chamado por scripts/kolla/kolla.sh; o resultado vai para o kolla-ansible com `-e @<arquivo>`.
"""
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

facts = data.get("ansible_facts", {})
# Normalize setup facts: ansible-core returns many keys prefixed with
# "ansible_", while Kolla roles/filters read unprefixed keys from
# ansible_facts (e.g. interfaces, service_mgr, python, <iface>).
for key, value in list(facts.items()):
    if key.startswith("ansible_"):
        short_key = key[len("ansible_"):]
        facts.setdefault(short_key, value)
# Kolla roles may access ansible_facts.hostname directly.
# Some distros expose only ansible_hostname in collected facts.
if "hostname" not in facts and "ansible_hostname" in facts:
    facts["hostname"] = facts["ansible_hostname"]
# Kolla roles may also access ansible_facts.python.version.* directly.
# Some environments expose only ansible_python in collected facts.
if "python" not in facts and "ansible_python" in facts:
    facts["python"] = facts["ansible_python"]
# Kolla prechecks expects ansible_facts.service_mgr.
if "service_mgr" not in facts:
    if "ansible_service_mgr" in facts:
        facts["service_mgr"] = facts["ansible_service_mgr"]
    elif "proc_cmdline" in facts and "init=" in str(facts["proc_cmdline"]):
        # Best-effort fallback for systems where setup omits service manager fact.
        facts["service_mgr"] = "systemd"
facts["os_family"] = "Debian"
facts["distribution"] = "Ubuntu"
facts["distribution_release"] = "noble"
facts["distribution_major_version"] = "24"

with open(dst, "w", encoding="utf-8") as f:
    json.dump({"ansible_facts": facts}, f)
