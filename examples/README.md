# Local input examples

Copy only the contents you need into your external build root. Example paths are illustrative and do not identify an actual tool binary.

`launch.txt` belongs alongside a tool under `C:\PNWC-PE\Source\Tools\<Category>\<Tool>`. Each non-comment line contains exactly four pipe-separated fields:

```text
Menu label|relative executable path|arguments|gui
Menu label|relative executable path|arguments|console
```

Paths must remain inside the tool's folder. Do not add pipes or line breaks inside a field. Arguments are trusted local command input, including in console entries. Review any launch file received from someone else. The generated `tools.csv` has fields `Category,Name,Path,Args,Console`; it is build output, not required input.

Use x64 portable binaries. Leave credentials out of command arguments. `launch.txt.example` intentionally uses a fictitious executable and must be edited and renamed before use.
