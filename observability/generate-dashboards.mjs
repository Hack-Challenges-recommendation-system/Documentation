import { mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const output = join(dirname(fileURLToPath(import.meta.url)), "grafana", "dashboards");
const prometheus = { type: "prometheus", uid: "prometheus" };
const loki = { type: "loki", uid: "loki" };

function target(expr, legendFormat = "") {
  return { expr, legendFormat, refId: "A", editorMode: "code", range: true };
}

function panel(title, expr, gridPos, type = "timeseries", unit = "short", legendFormat = "", description = "") {
  const options = type === "stat"
    ? {
        reduceOptions: { calcs: ["lastNotNull"], fields: "", values: false },
        orientation: "auto",
        textMode: "auto",
        colorMode: "none",
        graphMode: "area",
        justifyMode: "auto",
      }
    : {
        legend: { displayMode: "list", placement: "bottom", calcs: [] },
        tooltip: { mode: "multi", sort: "desc" },
      };
  return {
    title,
    description,
    type,
    datasource: prometheus,
    targets: [target(expr, legendFormat)],
    gridPos,
    options,
    fieldConfig: {
      defaults: {
        unit,
        ...(type === "timeseries" && unit === "percentunit" ? { min: 0, max: 1 } : {}),
        color: { mode: "palette-classic" },
        custom: type === "timeseries"
          ? { drawStyle: "line", lineWidth: 2, fillOpacity: 12, showPoints: "never", spanNulls: true }
          : undefined,
      },
      overrides: [],
    },
  };
}

function logsPanel(title, expr, gridPos) {
  return {
    title,
    type: "logs",
    datasource: loki,
    targets: [{ expr, refId: "A", queryType: "range" }],
    gridPos,
    options: { showTime: true, showLabels: false, showCommonLabels: false, wrapLogMessage: true, enableLogDetails: true },
  };
}

function thresholds(entry, steps, colorMode = "background") {
  entry.options.colorMode = colorMode;
  entry.fieldConfig.defaults.color = { mode: "thresholds" };
  entry.fieldConfig.defaults.thresholds = { mode: "absolute", steps };
  return entry;
}

function dashboard(uid, title, tags, panels) {
  return {
    uid,
    title,
    tags,
    timezone: "browser",
    schemaVersion: 41,
    version: 1,
    refresh: "15s",
    time: { from: "now-1h", to: "now" },
    graphTooltip: 1,
    editable: false,
    panels: panels.map((entry, index) => ({ id: index + 1, ...entry })),
  };
}

const system = dashboard("alpha-system", "01 · Состояние системы", ["alfa-course", "operations"], [
  thresholds(panel("Работающих сервисов", 'sum(up{job="application"})', { x: 0, y: 0, w: 6, h: 4 }, "stat", "short", "", "Из шести Java-сервисов"), [{ color: "red", value: null }, { color: "orange", value: 1 }, { color: "green", value: 6 }]),
  panel("Запросов в секунду", 'sum(rate(http_server_requests_seconds_count{job="application",uri!~".*(health|prometheus).*"}[5m])) or vector(0)', { x: 6, y: 0, w: 6, h: 4 }, "stat", "reqps"),
  thresholds(panel("Ошибки 5xx", '(sum(rate(http_server_requests_seconds_count{job="application",status=~"5..",uri!~".*(health|prometheus).*"}[5m])) or vector(0)) / clamp_min((sum(rate(http_server_requests_seconds_count{job="application",uri!~".*(health|prometheus).*"}[5m])) or vector(0)), 0.000001)', { x: 12, y: 0, w: 6, h: 4 }, "stat", "percentunit"), [{ color: "green", value: null }, { color: "orange", value: 0.01 }, { color: "red", value: 0.05 }]),
  panel("P95 ответа", 'histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{job="application",uri!~".*(health|prometheus).*"}[5m])))', { x: 18, y: 0, w: 6, h: 4 }, "stat", "s"),
  panel("Доступность по сервисам", 'up{job="application"}', { x: 0, y: 4, w: 12, h: 8 }, "timeseries", "short", "{{service}}"),
  panel("Нагрузка по сервисам", 'sum by (service) (rate(http_server_requests_seconds_count{job="application",uri!~".*(health|prometheus).*"}[5m])) or sum by (service) (up{job="application"} * 0)', { x: 12, y: 4, w: 12, h: 8 }, "timeseries", "reqps", "{{service}}"),
  panel("P95 времени ответа по сервисам", 'histogram_quantile(0.95, sum by (service, le) (rate(http_server_requests_seconds_bucket{job="application",uri!~".*(health|prometheus).*"}[5m])))', { x: 0, y: 12, w: 12, h: 8 }, "timeseries", "s", "{{service}}"),
  panel("Доля ошибок 5xx по сервисам", '(sum by (service) (rate(http_server_requests_seconds_count{job="application",status=~"5..",uri!~".*(health|prometheus).*"}[5m])) or sum by (service) (up{job="application"} * 0)) / clamp_min((sum by (service) (rate(http_server_requests_seconds_count{job="application",uri!~".*(health|prometheus).*"}[5m])) or sum by (service) (up{job="application"} * 0)), 0.000001)', { x: 12, y: 12, w: 12, h: 8 }, "timeseries", "percentunit", "{{service}}"),
  panel("Память JVM, heap", 'sum by (service) (jvm_memory_used_bytes{job="application",area="heap"})', { x: 0, y: 20, w: 12, h: 8 }, "timeseries", "bytes", "{{service}}"),
  panel("Состояние снимка продуктовых метрик", 'business_snapshot_success{service="metric-service"}', { x: 12, y: 20, w: 12, h: 8 }, "timeseries", "short", "1 = актуален, 0 = ошибка"),
  thresholds(panel("Материалов в каталоге", 'catalog_materials{service="catalog-service"}', { x: 0, y: 28, w: 12, h: 5 }, "stat"), [{ color: "red", value: null }, { color: "green", value: 1 }]),
  panel("Событий в базе", 'sum(business_events)', { x: 12, y: 28, w: 12, h: 5 }, "stat"),
]);

const recommendation = dashboard("alpha-recommendation", "02 · Рекомендации и LLM", ["alfa-course", "recommendation"], [
  panel("Выдано подборок", 'sum(recommendation_responses_total)', { x: 0, y: 0, w: 6, h: 4 }, "stat"),
  panel("Доля LLM-подборок", 'sum(recommendation_responses_total{engine="llm"}) / clamp_min(sum(recommendation_responses_total), 1)', { x: 6, y: 0, w: 6, h: 4 }, "stat", "percentunit"),
  panel("Переходов на baseline", 'sum(recommendation_fallbacks_total)', { x: 12, y: 0, w: 6, h: 4 }, "stat"),
  panel("Токенов модели", 'sum(recommendation_llm_tokens_total)', { x: 18, y: 0, w: 6, h: 4 }, "stat"),
  panel("Подборки по движку", 'sum by (engine) (recommendation_responses_total)', { x: 0, y: 4, w: 12, h: 8 }, "timeseries", "short", "{{engine}}"),
  panel("Причины перехода на baseline", 'sum by (reason) (recommendation_fallbacks_total)', { x: 12, y: 4, w: 12, h: 8 }, "timeseries", "short", "{{reason}}"),
  panel("P95 времени подбора", 'histogram_quantile(0.95, sum by (engine, le) (rate(recommendation_response_duration_seconds_bucket[5m])))', { x: 0, y: 12, w: 12, h: 8 }, "timeseries", "s", "{{engine}}"),
  panel("Доля попаданий в кэш", 'sum(recommendation_responses_total{cache="hit"}) / clamp_min(sum(recommendation_responses_total), 1)', { x: 12, y: 12, w: 12, h: 8 }, "timeseries", "percentunit"),
  panel("Вызовы LLM по исходу", 'sum by (outcome) (recommendation_llm_calls_total)', { x: 0, y: 20, w: 12, h: 8 }, "timeseries", "short", "{{outcome}}"),
  panel("P95 времени вызова LLM", 'histogram_quantile(0.95, sum by (outcome, le) (rate(recommendation_llm_duration_seconds_bucket[5m])))', { x: 12, y: 20, w: 12, h: 8 }, "timeseries", "s", "{{outcome}}"),
  panel("Токены по направлению", 'sum by (direction) (recommendation_llm_tokens_total)', { x: 0, y: 28, w: 12, h: 8 }, "timeseries", "short", "{{direction}}"),
  panel("Средний размер подборки", 'sum(recommendation_items_sum) / clamp_min(sum(recommendation_items_count), 1)', { x: 12, y: 28, w: 12, h: 8 }, "timeseries", "short"),
]);

const product = dashboard("alpha-product", "03 · События и A/B", ["alfa-course", "product"], [
  panel("Событий в базе", 'sum(business_events)', { x: 0, y: 0, w: 6, h: 4 }, "stat"),
  panel("Событий приложения", 'sum(business_events{source="app"})', { x: 6, y: 0, w: 6, h: 4 }, "stat"),
  panel("Участников эксперимента", 'sum(business_experiment_users)', { x: 12, y: 0, w: 6, h: 4 }, "stat"),
  panel("CTR варианта LLM", 'business_experiment_ctr{variant="llm"}', { x: 18, y: 0, w: 6, h: 4 }, "stat", "percentunit"),
  panel("События по типу", 'sum by (type) (business_events)', { x: 0, y: 4, w: 12, h: 8 }, "timeseries", "short", "{{type}}"),
  panel("Источники событий", 'sum by (source) (business_events)', { x: 12, y: 4, w: 12, h: 8 }, "timeseries", "short", "{{source}}"),
  panel("Воронка рекомендаций по вариантам", 'business_experiment_impressions or business_experiment_clicks or business_experiment_starts or business_experiment_completions', { x: 0, y: 12, w: 24, h: 8 }, "timeseries", "short", "{{__name__}} · {{variant}}"),
  panel("CTR по вариантам", 'business_experiment_ctr', { x: 0, y: 20, w: 8, h: 8 }, "timeseries", "percentunit", "{{variant}}"),
  panel("Начали после показа", 'business_experiment_start_rate', { x: 8, y: 20, w: 8, h: 8 }, "timeseries", "percentunit", "{{variant}}"),
  panel("Завершили после начала", 'business_experiment_completion_rate', { x: 16, y: 20, w: 8, h: 8 }, "timeseries", "percentunit", "{{variant}}"),
  panel("Возвращаемость по вариантам", 'business_experiment_return_rate', { x: 0, y: 28, w: 12, h: 8 }, "timeseries", "percentunit", "{{variant}}"),
  panel("Пользователи по вариантам", 'business_experiment_users', { x: 12, y: 28, w: 12, h: 8 }, "timeseries", "short", "{{variant}}"),
]);

const logs = dashboard("alpha-logs", "04 · Журналы сервисов", ["alfa-course", "logs"], [
  logsPanel("Ошибки и предупреждения", '{service_name=~"api-gateway|auth-service|profile-service|catalog-service|metric-service|recommendation-service"} | json | log_level=~"WARN|ERROR" | line_format "{{.message}}"', { x: 0, y: 0, w: 24, h: 12 }),
  logsPanel("Журнал рекомендателя", '{service_name="recommendation-service"} | json | line_format "{{.message}}"', { x: 0, y: 12, w: 24, h: 12 }),
  logsPanel("Журнал gateway", '{service_name="api-gateway"} | json | line_format "{{.message}}"', { x: 0, y: 24, w: 24, h: 12 }),
]);

await mkdir(output, { recursive: true });
for (const [name, data] of [
  ["system.json", system],
  ["recommendation.json", recommendation],
  ["product.json", product],
  ["logs.json", logs],
]) {
  await writeFile(join(output, name), JSON.stringify(data, null, 2) + "\n", "utf8");
}
