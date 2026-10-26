# Building Agent-Ready Internal Developer Platforms

Hands-on workshop. You run the platform on your laptop, in a [kind](https://kind.sigs.k8s.io/) cluster, against a fork of this repository.

## Before the session

Docker needs 12 GB of memory (16 recommended) and 4 CPUs. Then:

```bash
git clone https://github.com/<you>/agentic-idp-packt.git
cd agentic-idp-packt
gh repo set-default <you>/agentic-idp-packt
export GH_REPO=<you>/agentic-idp-packt

./labs/00-setup/local/preflight.sh
cp labs/00-setup/local/.env.example labs/00-setup/local/.env
./labs/00-setup/local/bootstrap.sh
```

Fill in `.env` with your fork URL and the OpenRouter key you were given. The full steps are in [labs/00-setup/local/README.md](labs/00-setup/local/README.md).

When the bootstrap finishes, `orders` and `runbooks` are `Synced` and `Healthy`. That is the state after Lab 2.

## Labs

| Lab | What you do |
|---|---|
| [00 Setup](labs/00-setup/) | Your cluster and fork, before the session |
| [01 Golden path](labs/01-golden-path/) | Ship `orders` (guided demo) |
| [02 Knowledge base](labs/02-knowledge-base/) | Docs generated from the platform (guided demo) |
| [03 Hermes](labs/03-hermes-triage/) | Deploy the agent and let it triage `orders` |
| [04 Guardrails](labs/04-guardrails-recovery/) | Policy, drift, a bad pull request, and the kill switch |

Labs 3 and 4 are the hands-on work. Labs 1 and 2 are already applied on a bootstrapped cluster.

## Slides

Follow along with the deck: [PDF](slides/agentic-idp-workshop.pdf) or [PowerPoint](slides/agentic-idp-workshop.pptx). Copy commands from the lab READMEs, not from the slides.

Reset a broken cluster with `kind delete cluster --name agentic-idp`, then run `bootstrap.sh` again.
