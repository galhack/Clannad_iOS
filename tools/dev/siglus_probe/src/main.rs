//! Small read-only probe for Siglus assets used by the CLANNAD Apple port.
//!
//! Why this exists: the host engine needs a window to boot, but most port
//! questions (which Gameexe keys are used, what a `.dbs` database contains,
//! which scene names a `Scene.pck` holds) can be answered headlessly. This
//! binary links only `siglus_assets` (no wgpu/winit), so it builds quickly.
//!
//! Commands:
//!   siglus_probe gameexe <project-dir>        decoded Gameexe text on stdout
//!   siglus_probe dbs <file.dbs> [--cjk]       decoded database strings
//!   siglus_probe scenes <Scene.pck>           scene names from the pack header
//!   siglus_probe stats <file.dbs>             row/column counts per database
//!
//! It never prints the 16-byte secondary key.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use siglus_assets::dbs::DbsDatabase;
use siglus_assets::gameexe::{GameexeDecodeOptions, decode_gameexe_dat_bytes};
use siglus_assets::scene_pck::{ScenePck, ScenePckDecodeOptions};

/// Gameexe names accepted by the engine (localized names included).
const GAMEEXE_CANDIDATES: &[&str] = &[
    "Gameexe.dat",
    "Gameexe.ini",
    "gameexe.dat",
    "gameexe.ini",
    "GameexeEN.dat",
    "GameexeEN.ini",
    "GameexeZH.dat",
    "GameexeZH.ini",
    "GameexeZHTW.dat",
    "GameexeZHTW.ini",
    "GameexeDE.dat",
    "GameexeDE.ini",
    "GameexeES.dat",
    "GameexeES.ini",
    "GameexeFR.dat",
    "GameexeFR.ini",
    "GameexeID.dat",
    "GameexeID.ini",
];

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().context(
        "usage: siglus_probe <gameexe|dbs|scenes|stats> <path> [--cjk]",
    )?;
    match command.as_str() {
        "gameexe" => cmd_gameexe(PathBuf::from(args.next().context("missing project dir")?)),
        "dbs" => cmd_dbs(
            PathBuf::from(args.next().context("missing .dbs path")?),
            args.any(|a| a == "--cjk"),
        ),
        "stats" => cmd_stats(PathBuf::from(args.next().context("missing .dbs path")?)),
        "scenes" => cmd_scenes(PathBuf::from(args.next().context("missing Scene.pck path")?)),
        "scn" => {
            let project = PathBuf::from(args.next().context("missing project dir")?);
            let scene = args.next().context("missing scene name or index")?;
            let cjk_only = args.any(|a| a == "--cjk");
            cmd_scn(project, scene, cjk_only)
        }
        other => bail!("unknown command: {other}"),
    }
}

fn find_gameexe(project: &Path) -> Result<PathBuf> {
    for name in GAMEEXE_CANDIDATES {
        let path = project.join(name);
        if path.is_file() {
            return Ok(path);
        }
    }
    bail!("no Gameexe candidate under {}", project.display())
}

fn cmd_gameexe(project: PathBuf) -> Result<()> {
    let path = find_gameexe(&project)?;
    let raw = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    let ext_is_ini = path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("ini"));
    let text = if ext_is_ini {
        String::from_utf8(raw).context("Gameexe.ini is not UTF-8")?
    } else {
        let opt = GameexeDecodeOptions::from_project_dir(&project)?;
        decode_gameexe_dat_bytes(&raw, &opt)
            .with_context(|| format!("decode {}", path.display()))?
            .0
    };
    println!("{text}");
    Ok(())
}

fn cmd_dbs(path: PathBuf, cjk_only: bool) -> Result<()> {
    let db = DbsDatabase::load(&path).with_context(|| format!("load {}", path.display()))?;
    println!(
        "# {} type={} rows={} cols={}",
        path.display(),
        db.db_type(),
        db.row_count(),
        db.column_count()
    );
    let mut printed = 0usize;
    let mut cjk = 0usize;
    for row in db.rows() {
        for col in db.columns() {
            let Ok(Some(text)) = db.get_data_str(row.call_no, col.call_no) else {
                continue;
            };
            if text.is_empty() {
                continue;
            }
            let has_cjk = text.chars().any(|c| ('\u{4E00}'..='\u{9FFF}').contains(&c));
            if has_cjk {
                cjk += 1;
            }
            if cjk_only && !has_cjk {
                continue;
            }
            printed += 1;
            println!("{:>8}/{:>8}: {}", row.call_no, col.call_no, text);
        }
    }
    println!("# printed {printed} strings ({cjk} contain CJK ideographs)");
    Ok(())
}

fn cmd_stats(path: PathBuf) -> Result<()> {
    let db = DbsDatabase::load(&path).with_context(|| format!("load {}", path.display()))?;
    println!(
        "{}: type={} rows={} cols={}",
        path.display(),
        db.db_type(),
        db.row_count(),
        db.column_count()
    );
    Ok(())
}

/// Dump the decompressed script string table of one scene.
///
/// Scene chunks are LZSS-compressed and XOR-keyed with the 16-byte secondary
/// key, so this is the only way to see what a scene script really contains
/// without running the VM. String i is XORed with `28807 * i` as u16, exactly
/// like `SceneStream::get_string`.
fn cmd_scn(project: PathBuf, scene: String, cjk_only: bool) -> Result<()> {
    let pck_path = siglus_scene_vm_scene_path(&project)?;
    let opt = ScenePckDecodeOptions::from_project_dir(&project)?;
    let pack = ScenePck::load_lazy(&pck_path, &opt)
        .with_context(|| format!("load {}", pck_path.display()))?;
    let scn_no = pack
        .find_scene_no(&scene)
        .with_context(|| format!("scene not found: {scene}"))?;
    let chunk = pack.scn_data_slice(scn_no)?;
    let chunk = chunk.as_ref();
    if chunk.len() < 33 * 4 {
        bail!("scene chunk too short");
    }
    let rd = |i: usize| i32::from_le_bytes(chunk[i * 4..i * 4 + 4].try_into().unwrap());
    let idx_ofs = rd(3).max(0) as usize;
    let idx_cnt = rd(4).max(0) as usize;
    let list_ofs = rd(5).max(0) as usize;
    let str_cnt = rd(6).max(0) as usize;
    println!(
        "# scene={} no={} chunk={}B strings={} codec={:?}",
        scene,
        scn_no,
        chunk.len(),
        str_cnt,
        pack.string_codec
    );
    let xor = pack.string_codec == siglus_assets::scene_pck::SceneStringCodec::Xor;
    let mut cjk = 0usize;
    for i in 0..str_cnt.min(idx_cnt) {
        let p = idx_ofs + i * 8;
        if p + 8 > chunk.len() {
            break;
        }
        let off = i32::from_le_bytes(chunk[p..p + 4].try_into().unwrap()).max(0) as usize;
        let len = i32::from_le_bytes(chunk[p + 4..p + 8].try_into().unwrap()).max(0) as usize;
        let start = list_ofs + off * 2;
        let end = start + len * 2;
        if end > chunk.len() {
            continue;
        }
        let key = (28807u32).wrapping_mul(i as u32) as u16;
        let units: Vec<u16> = chunk[start..end]
            .chunks_exact(2)
            .map(|c| {
                let raw = u16::from_le_bytes([c[0], c[1]]);
                if xor { raw ^ key } else { raw }
            })
            .take_while(|w| *w != 0)
            .collect();
        let text = String::from_utf16_lossy(&units);
        if text.is_empty() {
            continue;
        }
        let has_cjk = text.chars().any(|c| ('\u{4E00}'..='\u{9FFF}').contains(&c));
        if has_cjk {
            cjk += 1;
        }
        if cjk_only && !has_cjk {
            continue;
        }
        println!("{i:>4}: {text}");
    }
    println!("# {cjk} strings contain CJK ideographs");
    Ok(())
}

/// Resolve the scene archive the same way the host engine does: prefer the
/// archive next to the resolved localized Gameexe (`SceneZH.pck` for
/// `GameexeZH.dat`), then plain `Scene.pck`.
fn siglus_scene_vm_scene_path(project: &Path) -> Result<PathBuf> {
    for name in [
        "SceneZH.pck", "Scene.pck", "SceneEN.pck", "SceneZHTW.pck", "SceneDE.pck",
        "SceneES.pck", "SceneFR.pck", "SceneID.pck",
    ] {
        let path = project.join(name);
        if path.is_file() {
            return Ok(path);
        }
        let data = project.join("Data").join(name);
        if data.is_file() {
            return Ok(data);
        }
    }
    bail!("no Scene*.pck under {}", project.display())
}

fn cmd_scenes(path: PathBuf) -> Result<()> {
    let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    if bytes.len() < 23 * 4 {
        bail!("{} is too short for a Scene.pck header", path.display());
    }
    let rd = |i: usize| i32::from_le_bytes(bytes[i * 4..i * 4 + 4].try_into().unwrap());
    // 23 x i32 header, little-endian; the shipped CLANNAD pack has no
    // "pack_scn" signature.
    let idx_ofs = rd(13).max(0) as usize;
    let idx_cnt = rd(14).max(0) as usize;
    let list_ofs = rd(15).max(0) as usize;
    println!(
        "# {} header_size={} scenes={} scn_data_exe_angou_mod={}",
        path.display(),
        rd(0),
        idx_cnt,
        rd(21)
    );
    for i in 0..idx_cnt {
        let p = idx_ofs + i * 8;
        if p + 8 > bytes.len() {
            break;
        }
        let off = i32::from_le_bytes(bytes[p..p + 4].try_into().unwrap()).max(0) as usize;
        let len = i32::from_le_bytes(bytes[p + 4..p + 8].try_into().unwrap()).max(0) as usize;
        let start = list_ofs + off * 2;
        let end = start + len * 2;
        if end > bytes.len() {
            continue;
        }
        let units: Vec<u16> = bytes[start..end]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .take_while(|w| *w != 0)
            .collect();
        println!("{i:>4} {}", String::from_utf16_lossy(&units));
    }
    Ok(())
}
