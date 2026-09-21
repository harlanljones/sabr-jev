defmodule SabrJevWeb.AboutLive do
  use SabrJevWeb, :live_view

  alias SabrJev.Catalog

  @impl true
  def mount(_params, _session, socket) do
    case Catalog.load() do
      {:ok, catalog} ->
        {:ok, assign(socket, :provenance, catalog["provenance"])}

      {:error, reason} ->
        {:ok, assign(socket, :provenance, %{"load_error" => inspect(reason)})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="about">
      <header>
        <p class="eyebrow">Formulas &amp; provenance</p>
        <h1>About Sabr-Jev</h1>
        <nav aria-label="About">
          <a href={~p"/"}>Workbench</a>
          {" | "}
          <a href={~p"/about"} aria-current="page">About &amp; formulas</a>
        </nav>
      </header>

      <section aria-labelledby="ops-heading">
        <h2 id="ops-heading">OPS+ (Sabr-Jev)</h2>
        <p>
          Custom recipe, not Fangraphs/Baseball-Reference parity. League OBP/SLG are
          summed league-year counts; traded players use PA-weighted league context.
        </p>
        <pre>weighted_lg_OBP = sum(stint_PA * stint_league_OBP) / total_PA
    weighted_lg_SLG = sum(stint_PA * stint_league_SLG) / total_PA
    weighted_Teams_BPF = sum(stint_PA * Teams[year,team].BPF) / total_PA
    park_adjustment = (1 + weighted_Teams_BPF/100) / 2
    OPS+ (Sabr-Jev) = 100 * (OBP/(weighted_lg_OBP*park_adjustment)
                            + SLG/(weighted_lg_SLG*park_adjustment) - 1)</pre>
        <p>
          Teams.BPF is Lahman's batting park factor; 100 is neutral in this custom half-schedule adjustment.
        </p>
      </section>

      <section aria-labelledby="woba-heading">
        <h2 id="woba-heading">wOBA</h2>
        <pre>wOBA = (wBB*(BB-IBB) + wHBP*HBP + w1B*1B + w2B*X2B + w3B*X3B + wHR*HR)
           / (AB + BB - IBB + HBP + SF)</pre>
        <p>
          Year weights come only from the frozen <code>data/woba_weights.csv</code>
          (Fangraphs Guts constants export, cited). Missing year → wOBA unavailable.
          No runtime scrape.
        </p>
      </section>

      <section aria-labelledby="fip-heading">
        <h2 id="fip-heading">FIP + cFIP</h2>
        <pre>IP = IPouts / 3
    ERA = 27 * ER / IPouts
    component = (13*HR + 3*(BB+HBP) - 2*SO) / IP
    league_cFIP = league_ERA - league_component
    FIP = component + weighted_cFIP (outs-weighted for traded pitchers)
    K-BB% = (SO-BB) / BFP</pre>
        <p>cFIP is derived from Lahman aggregates, never from the weights file.</p>
      </section>

      <section aria-labelledby="counting-heading">
        <h2 id="counting-heading">Counting rules</h2>
        <p>
          Sum counts across stints before dividing. Missing optional HBP/SF/IBB is
          assumed zero with a warning; missing core inputs or invalid denominators
          leave the metric unavailable, never invented.
        </p>
      </section>

      <section aria-labelledby="latch-heading">
        <h2 id="latch-heading">Confidence latch (provisional thresholds)</h2>
        <p>
          Choice/Score: act ≥ 0.8, review ≥ 0.5, else escalate; “other” always
          escalates; insufficient sample cannot act. Noul derives max(p, 1-p):
          act ≥ 0.85, otherwise review — Noul never escalates a card alone.
          Thresholds are provisional (mini-labeled requires N≥30).
        </p>
      </section>

      <section aria-labelledby="prov-heading">
        <h2 id="prov-heading">Provenance</h2>
        <dl class="provenance">
          <div>
            <dt>Formula version</dt><dd>{@provenance["formula_version"]}</dd>
          </div>
          <div>
            <dt>Latest season</dt><dd>{@provenance["latest_season"]}</dd>
          </div>
          <div>
            <dt>License</dt><dd>{@provenance["license"]}</dd>
          </div>
          <div>
            <dt>Scope</dt><dd>{@provenance["scope"]}</dd>
          </div>
          <div>
            <dt>Oracle policy</dt><dd>{@provenance["oracle_policy"]}</dd>
          </div>
          <div>
            <dt>Manifest</dt><dd><code>{@provenance["manifest_sha256"]}</code></dd>
          </div>
        </dl>
      </section>

      <section aria-labelledby="eval-heading">
        <h2 id="eval-heading">Evaluation status</h2>
        <p>Prospective evaluation: accuracy pending. No accuracy claim is made.</p>
        <p>
          2024 → 2025 oracle joins are retrospective plumbing only. Capture must
          precede the outcome season (conservative January 1 cutoff). The local
          ledger is append-only and hash chained but cannot prove external capture
          time.
        </p>
      </section>

      <footer>
        <p>
          Data source: <a href="https://sabr.org/lahman-database/">Lahman Baseball Database</a>.
          no Fangraphs scrape in v1. No Retrosheet data in v1.
        </p>
      </footer>
    </main>
    """
  end
end
