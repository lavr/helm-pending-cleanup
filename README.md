# pending-cleanup Helm Plugin

`pending-cleanup` is a small Helm plugin that detects **stale releases** stuck
in any `pending-*` state and either lists or purges their Helm‐owned Secrets.
It is designed for CI pipelines and operators who need to keep clusters tidy.

---

## Features

* Detects releases whose last deployment is older than a given **duration**  
  (`30m`, `4h`, `2d`, …) **or** a UNIX **epoch timestamp**.
* Supports two actions:  
  * **`print`** – list matching Secrets.  
  * **`delete`** – remove matching Secrets.
* **Silent by default**; enable `--verbose` for detailed logs.
* Fails fast with non-zero exit codes on any error.

---

## Requirements

Plugin depends on Helm, kubectk, jq, bash

---

## Installation

```bash
# 1) Create plugin directory
mkdir -p ~/.config/helm/plugins/pending-cleanup

# 2) Place plugin.yaml and pending-cleanup script here
cp plugin.yaml pending-cleanup ~/.config/helm/plugins/pending-cleanup/

# 3) Make the script executable
chmod +x ~/.config/helm/plugins/pending-cleanup/pending-cleanup

# 4) Verify
helm plugin list
```

## Usage
```
helm pending-cleanup [flags] <release> <age> <action>

Arguments:
  release   Helm release name.
  age       Threshold age (epoch seconds) OR duration string
            (e.g. 30m, 2h, 7d).
  action    What to do when matched: print | delete

Flags:
  -v, --verbose             Verbose log output.
  -n, --namespace <value>   Kubernetes namespace to target.
  -h, --help                Show help and exit.
```



## Examples

1. Delete helm secret for a stalled release older than 2 hours

    helm pending-cleanup my-release 2h delete

2. List helm secrets for helm release stalled before specific epoch time

    # List if last stalled deployment occurred before 12 May 2025 00:00 UTC
    helm pending-cleanup my-release 1715558400 delete


## Contributing

Issues and pull requests are welcome! Please keep all comments, commit messages, and code comments in clear,
technical English.

## License

This plugin is released under the MIT License. See LICENSE for details.