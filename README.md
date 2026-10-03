# mac-shortcuts-app

A Dock app, a command-line script and macOS Shortcuts for running an EKS lab cluster
without leaving it billing overnight.

![EKS Lab icon](icon/icon.png)

## EKS Lab.app

Click it in the Dock and you get:

- a **connection pill**: green when your AWS SSO session is valid, red with a **Sign in**
  button that runs `aws sso login --profile <your profile>` and waits for the browser
- a **status card**: platform nodes, GPU nodes and the cost per hour, refreshed every 20 s
- **Start EKS** (platform nodes, waits until the Solo UI answers), **Start with GPUs**,
  **Stop GPUs only** and **Stop EKS** (every node group to 0, control plane stays, asks first)
- **Demo console**: opens the local demo console, starting it with `./run.sh` if it is down
- **Solo UI** and **Log** links

Every action runs `eks-lab` in the background and posts a macOS notification when it is done.

## Install

```bash
./install.sh            # script to ~/.local/bin, app to ~/Applications, adds it to the Dock
$EDITOR ~/.config/eks-lab/config
```

Needs the AWS CLI, kubectl and the Xcode command line tools (`xcode-select --install`).

## eks-lab

```bash
eks-lab status          # node groups, billing instances, every running instance
eks-lab up              # platform nodes, waits for the Solo UI
eks-lab gpu-up          # up, then the GPU node group (gpu.sh up)
eks-lab gpu-down        # GPU node group to 0
eks-lab down            # every node group to 0; waits until EC2 shows nothing billing
eks-lab login           # aws sso login for the configured profile
eks-lab console         # open the demo console, starting it if needed
eks-lab up --background # return at once, notify when done (what the app and Shortcuts use)
```

Stop never trusts the node group's status: PodDisruptionBudgets can stall a drain while
the instances keep billing, so it waits until EC2 reports no instances for the cluster.
Only one start or stop runs at a time. Log: `~/Library/Logs/eks-lab.log`.

## Shortcuts

`shortcuts/` has signed **Start EKS**, **Start EKS with GPUs**, **Stop EKS GPUs** and
**Stop EKS**. Double-click to import, then turn on **Settings → Advanced → Allow Running
Scripts** in Shortcuts. They appear in the Shortcuts menu-bar icon and work with Siri.

## Changing the app

Edit `app/EKSLab.swift` and run `./build.sh`. To check the layout without clicking anything:

```bash
"$HOME/Applications/EKS Lab.app/Contents/MacOS/EKSLab" --snapshot /tmp/a.png 2 0 0.97 0 dark
# args: out.png platform gpus cost busy [dark] [console-down]; platform "login" shows the signed-out state
```

The icon is `icon/icon.html`, rendered with headless Chrome and packed with `iconutil`.
