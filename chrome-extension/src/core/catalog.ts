import modelsJson from '../../../shared/models.json';
import languagesJson from '../../../shared/languages.json';

export interface ModelFile {
  quant: string;
  file: string;
  sizeBytes: number;
  sha256: string;
  url: string;
}
export interface ModelEntry {
  id: string;
  size: '0.8b' | '2b' | '8b';
  label: string;
  description: string;
  minRamGB: number;
  default: boolean;
  repo: string;
  defaultQuant: string;
  files: ModelFile[];
}
export interface Language {
  code: string;
  ja: string;
  en: string;
}

export const MODELS = modelsJson.models as ModelEntry[];
export const LICENSE = modelsJson.license;
export const LANGUAGES = languagesJson.languages as Language[];
export const EXTRA_TARGETS = (languagesJson as { extraTargets: Language[] }).extraTargets;
export const TARGET_LANGUAGES: Language[] = [...LANGUAGES, ...EXTRA_TARGETS];
export const STOP: string[] = modelsJson.generation.stop;

export type SizeId = ModelEntry['size'];
/** ブラウザ内 (WASM) で動かせるサイズ。8B はメモリ/ArrayBuffer(2GB) 制限のためローカルサーバー専用。 */
export const WASM_SIZES: SizeId[] = ['0.8b', '2b'];

export function getModel(size: SizeId): ModelEntry {
  const m = MODELS.find((x) => x.size === size);
  if (!m) throw new Error(`unknown model size: ${size}`);
  return m;
}

export function getModelFile(size: SizeId, quant?: string): ModelFile {
  const m = getModel(size);
  const f = m.files.find((x) => x.quant === (quant ?? m.defaultQuant)) ?? m.files[0];
  return f;
}

export function langLabel(code: string): string {
  return TARGET_LANGUAGES.find((l) => l.code === code)?.ja ?? code;
}

export function formatBytes(n: number): string {
  if (n >= 1024 ** 3) return `${(n / 1024 ** 3).toFixed(2)} GB`;
  return `${Math.round(n / 1024 ** 2)} MB`;
}
