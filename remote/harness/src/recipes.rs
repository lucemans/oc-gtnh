//! Every GTNH recipe, from the planner's dataset, indexed for one question:
//! what makes this, or what uses it.
//!
//! The dataset is the gzipped JSON the planner site downloads for itself.
//! There is no hosted API, and the site asks not to be polled, so the file is
//! fetched once by hand and named in the environment. Only what a question
//! needs is kept in memory: names, amounts, the machine, the tier and the cost.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use tracing::info;

/// where the planner publishes its datasets, and the file that names them
const PLANNER: &str = "https://gtnhplanner.com";
const MANIFEST: &str = "/datasets/gtnh/datasets.manifest.json";
/// where the dataset lands when nothing else is named
const DEFAULT_PATH: &str = "recipes.json.gz";

#[derive(Deserialize)]
struct Manifest {
    versions: Vec<ManifestVersion>,
}

#[derive(Deserialize)]
struct ManifestVersion {
    #[serde(default)]
    id: String,
    #[serde(default)]
    channel: String,
    #[serde(default, rename = "recipeDatasetPath")]
    recipe_dataset_path: String,
}

/// The dataset, loaded, or nothing when GTNH_RECIPES is `none`. The file is
/// downloaded once when it is not there yet, the way the planner site fetches
/// it for every visitor, and never again: the site asks not to be polled.
pub async fn prepare() -> Result<Option<Arc<Recipes>>> {
    let setting = std::env::var("GTNH_RECIPES").unwrap_or_else(|_| DEFAULT_PATH.to_string());
    if setting.eq_ignore_ascii_case("none") || setting.eq_ignore_ascii_case("off") {
        return Ok(None);
    }
    let path = PathBuf::from(setting);
    if !path.exists() {
        download(&path).await?;
    }
    let loaded = tokio::task::spawn_blocking(move || Recipes::load(&path)).await??;
    Ok(Some(Arc::new(loaded)))
}

async fn download(path: &Path) -> Result<()> {
    let base = std::env::var("GTNH_PLANNER_URL").unwrap_or_else(|_| PLANNER.to_string());
    let base = base.trim_end_matches('/');
    let http = reqwest::Client::builder()
        .user_agent(concat!("ocharness/", env!("CARGO_PKG_VERSION")))
        .build()?;
    info!(%base, "no recipe dataset on disk, fetching the planner's manifest");
    let manifest: Manifest = http
        .get(format!("{base}{MANIFEST}"))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await
        .context("reading the planner manifest")?;
    // the stable channel when there is one, else whatever is first
    let version = manifest
        .versions
        .iter()
        .find(|version| version.channel == "stable")
        .or_else(|| manifest.versions.first())
        .filter(|version| !version.recipe_dataset_path.is_empty());
    let Some(version) = version else {
        bail!("the planner manifest names no recipe dataset");
    };
    let url = if version.recipe_dataset_path.starts_with("http") {
        version.recipe_dataset_path.clone()
    } else {
        format!(
            "{base}/{}",
            version.recipe_dataset_path.trim_start_matches('/')
        )
    };
    info!(version = %version.id, channel = %version.channel, %url, "downloading the recipe dataset");
    let bytes = http
        .get(&url)
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    let partial = path.with_extension("part");
    tokio::fs::write(&partial, &bytes)
        .await
        .with_context(|| format!("writing {}", partial.display()))?;
    tokio::fs::rename(&partial, path).await?;
    info!(bytes = bytes.len(), path = %path.display(), "recipe dataset saved");
    Ok(())
}

#[derive(Deserialize)]
struct Dataset {
    #[serde(default)]
    recipes: Vec<RawRecipe>,
}

#[derive(Deserialize)]
struct RawRecipe {
    #[serde(default)]
    name: String,
    #[serde(default, rename = "machineType")]
    machine: String,
    #[serde(default, rename = "minimumTier")]
    tier: String,
    #[serde(default, rename = "durationTicks")]
    ticks: f64,
    #[serde(default)]
    eut: f64,
    #[serde(default)]
    inputs: Vec<RawStack>,
    #[serde(default)]
    outputs: Vec<RawStack>,
}

#[derive(Deserialize)]
struct RawStack {
    #[serde(default)]
    kind: String,
    #[serde(default, rename = "displayName")]
    name: String,
    #[serde(default)]
    amount: f64,
}

pub struct Stack {
    pub name: String,
    pub amount: f64,
    pub fluid: bool,
}

pub struct Recipe {
    pub name: String,
    pub machine: String,
    pub tier: String,
    pub ticks: f64,
    pub eut: f64,
    pub inputs: Vec<Stack>,
    pub outputs: Vec<Stack>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Makes,
    Uses,
}

pub struct Recipes {
    all: Vec<Recipe>,
}

fn stacks(raw: Vec<RawStack>) -> Vec<Stack> {
    raw.into_iter()
        .filter(|stack| !stack.name.is_empty())
        .map(|stack| Stack {
            fluid: stack.kind == "fluid",
            name: stack.name,
            amount: stack.amount,
        })
        .collect()
}

impl Recipes {
    pub fn from_reader(reader: impl std::io::Read) -> Result<Recipes> {
        let dataset: Dataset = serde_json::from_reader(std::io::BufReader::new(reader))
            .context("reading the recipe dataset")?;
        let all = dataset
            .recipes
            .into_iter()
            .map(|raw| Recipe {
                name: raw.name,
                machine: raw.machine,
                tier: raw.tier,
                ticks: raw.ticks,
                eut: raw.eut,
                inputs: stacks(raw.inputs),
                outputs: stacks(raw.outputs),
            })
            .collect();
        Ok(Recipes { all })
    }

    /// The dataset as downloaded, gzipped or not, by its name.
    pub fn load(path: &Path) -> Result<Recipes> {
        let started = Instant::now();
        let file =
            std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
        let recipes = if path.extension().is_some_and(|ext| ext == "gz") {
            Recipes::from_reader(flate2::read::GzDecoder::new(file))?
        } else {
            Recipes::from_reader(file)?
        };
        info!(
            recipes = recipes.all.len(),
            seconds = started.elapsed().as_secs_f64() as i64,
            "recipe dataset loaded"
        );
        Ok(recipes)
    }

    pub fn len(&self) -> usize {
        self.all.len()
    }

    /// Recipes whose outputs, or inputs, name the item. An exact name comes
    /// before a name that only contains the words, and a cheaper recipe before
    /// a dearer one, so the first few lines are the ones worth reading.
    pub fn search(
        &self,
        item: &str,
        direction: Direction,
        machine: Option<&str>,
        limit: usize,
    ) -> Vec<&Recipe> {
        let wanted = item.trim().to_lowercase();
        let machine = machine
            .map(|m| m.trim().to_lowercase())
            .filter(|m| !m.is_empty());
        let mut found: Vec<(u8, &Recipe)> = self
            .all
            .iter()
            .filter(|recipe| {
                machine
                    .as_ref()
                    .is_none_or(|m| recipe.machine.to_lowercase().contains(m))
            })
            .filter_map(|recipe| {
                let side = match direction {
                    Direction::Makes => &recipe.outputs,
                    Direction::Uses => &recipe.inputs,
                };
                let rank = side
                    .iter()
                    .map(|stack| {
                        let name = stack.name.to_lowercase();
                        if name == wanted {
                            0
                        } else if name.contains(&wanted) {
                            1
                        } else {
                            2
                        }
                    })
                    .min()
                    .unwrap_or(2);
                (rank < 2).then_some((rank, recipe))
            })
            .collect();
        found.sort_by(|a, b| {
            a.0.cmp(&b.0)
                .then_with(|| {
                    a.1.eut
                        .partial_cmp(&b.1.eut)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .then_with(|| {
                    a.1.ticks
                        .partial_cmp(&b.1.ticks)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        });
        found
            .into_iter()
            .take(limit)
            .map(|(_, recipe)| recipe)
            .collect()
    }
}

fn amount(stack: &Stack) -> String {
    if stack.fluid {
        format!("{:.0} L {}", stack.amount, stack.name)
    } else {
        format!("{:.0}x {}", stack.amount, stack.name)
    }
}

impl Recipe {
    /// One line the model can read: machine, tier, cost, then in and out.
    pub fn line(&self) -> String {
        let seconds = self.ticks / 20.0;
        let cost = if self.eut > 0.0 {
            format!(" {:.0} EU/t {seconds:.1}s", self.eut)
        } else if self.ticks > 0.0 {
            format!(" {seconds:.1}s")
        } else {
            String::new()
        };
        let tier = if self.tier.is_empty() {
            String::new()
        } else {
            format!(" [{}]", self.tier)
        };
        format!(
            "{}{tier}{cost}: {} -> {}",
            self.machine,
            self.inputs
                .iter()
                .map(amount)
                .collect::<Vec<_>>()
                .join(" + "),
            self.outputs
                .iter()
                .map(amount)
                .collect::<Vec<_>>()
                .join(" + "),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{"schemaVersion":1,"recipes":[
      {"name":"EBF: Steel","kind":"gregtech_machine","machineType":"Electric Blast Furnace","minimumTier":"HV","durationTicks":750,"eut":480,
       "inputs":[{"kind":"item","displayName":"Iron Dust","amount":1},{"kind":"fluid","displayName":"Oxygen","amount":1000}],
       "outputs":[{"kind":"item","displayName":"Steel Ingot","amount":1}]},
      {"name":"Macerator: Steel","machineType":"Macerator","minimumTier":"LV","durationTicks":300,"eut":8,
       "inputs":[{"kind":"item","displayName":"Steel Ingot","amount":1}],
       "outputs":[{"kind":"item","displayName":"Steel Dust","amount":1}]},
      {"name":"Extra","machineType":"Extruder","minimumTier":"MV","durationTicks":100,"eut":120,
       "inputs":[{"kind":"item","displayName":"Steel Ingot","amount":1}],
       "outputs":[{"kind":"item","displayName":"Steel Rod","amount":2}]}
    ]}"#;

    #[test]
    fn finds_what_makes_and_what_uses_an_item() {
        let recipes = Recipes::from_reader(SAMPLE.as_bytes()).unwrap();
        assert_eq!(recipes.len(), 3);
        let makes = recipes.search("steel ingot", Direction::Makes, None, 5);
        assert_eq!(makes.len(), 1);
        assert_eq!(
            makes[0].line(),
            "Electric Blast Furnace [HV] 480 EU/t 37.5s: 1x Iron Dust + 1000 L Oxygen -> 1x Steel Ingot"
        );
        let uses = recipes.search("Steel Ingot", Direction::Uses, None, 5);
        assert_eq!(uses.len(), 2);
        assert!(
            uses[0].line().starts_with("Macerator"),
            "cheapest first: {}",
            uses[0].line()
        );
        let only = recipes.search("steel", Direction::Uses, Some("extruder"), 5);
        assert_eq!(only.len(), 1);
    }
}
