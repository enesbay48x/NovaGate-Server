import sys, os

path = r"C:\Users\Pc\Downloads\çalışanzip\scripts\menu_ui.gd"
data = open(path, "rb").read()

print("LEN", len(data))
print("FIRST_1KB_HEX", data[:1024].hex(' '))
print("FIRST_1KB_ASCII", data[:1024])
print("LAST_1KB_HEX", data[-1024:].hex(' '))
print("LAST_1KB_ASCII", data[-1024:])

# Count meaningful markers
crlf = data.count(b'\r\n')
lf_only = data.count(b'\n') - crlf
tab = data.count(b'\t')
print("CRLF_COUNT", crlf, "LF_ONLY_COUNT", lf_only, "TAB_COUNT", tab)

# Look for first and last real newline positions
first_crlf = data.find(b'\r\n')
last_crlf = data.rfind(b'\r\n')
print("FIRST_CRLF_POS", first_crlf, "LAST_CRLF_POS", last_crlf)
