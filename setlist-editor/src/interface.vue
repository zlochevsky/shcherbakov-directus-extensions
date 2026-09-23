<script setup>
import { ref, computed, watch } from 'vue';
import { useApi } from '@directus/extensions-sdk';

/* ─────────────────────────────────────────────────────────────
   Схема (см. docs/directus.md в репозитории) — уточнено запросом
   к живой базе 2026-08-17, при расхождениях доверять этому месту,
   а не памяти.
   ───────────────────────────────────────────────────────────── */
const PERF_COLLECTION = 'perfs';   // коллекция исполнений
const WORK_COLLECTION = 'works';   // справочник песен
const EVENT_FK         = 'events_id'; // FK исполнения -> концерт (events)
const WORK_FK          = 'works_id';  // FK исполнения -> песня (works)
const NUMBER_FIELD     = 'num';       // порядок в программе — НЕ отправляем при
                                       // создании: Flow «Auto perf id» сам
                                       // проставляет id и num (max+1), если
                                       // они не пришли в payload. Если слать
                                       // num вручную отсюда, есть риск
                                       // разъехаться с чужими одновременными
                                       // правками того же концерта.
                                       // (было "number" — поле пересоздали под
                                       // другой тип 2026-09-22, см. perf-picker)

// Заголовок песни строим так же, как это делает layouts/miscellaneous/catalogue.html:
// name (с fname, если есть) — а если name пусто, то fincipit.
const WORK_TITLE_FIELDS = ['name', 'fname', 'incipit', 'fincipit', 'sort'];
const EXCLUDE_HIDDEN = true; // не предлагать works.hidden = true в автокомплите

// Булевы параметры исполнения, которые тычешь галочками прямо в строке.
// В perfs их около 19 (is_premiere, is_poem, is_bis, is_ensemble,
// with_mls, has_synth, sings_incomplete, ...) — сюда стоит выносить только
// то, что реально решается в момент ввода сетлиста. Остальное быстрее
// дозаполнить потом через табличный layout (spreadsheet-layout /
// super-table) на самой коллекции perfs, не отвлекаясь на ввод.
const PARAM_FIELDS = [
	{ key: 'is_premiere',          label: 'прем' },
	{ key: 'with_mls',             label: 'МС' },
	{ key: 'plays_mls_keyboards',  label: 'кл' },
	{ key: 'is_first',             label: 'перв' },
	{ key: 'is_last',              label: 'посл' },
	{ key: 'is_last_before_break', label: 'до ан' },
	{ key: 'is_first_after_break', label: 'п ан' },
];
/* ───────────────────────────────────────────────────────────── */

const props = defineProps({
	value: { type: [Array, Object], default: null },
	collection: { type: String, default: null },
	field: { type: String, default: null },
	primaryKey: { type: [String, Number], default: null },
});

// Интерфейс сам пишет изменения через api.post/patch/delete прямо в perfs,
// а не через value/emit('input', ...), поэтому событие 'input' само по себе
// не используется. НО декларация ниже всё равно обязательна: без неё Vue не
// знает, что Directus вешает на нас @input как кастомный listener поля, и
// молча приклеивает его как нативный DOM-обработчик к корневому <div> (через
// $attrs fallthrough). Тогда всплывающее нативное событие input от search-
// инпута внутри компонента долетает до этого листенера вместо значения поля,
// и при Save формы Directus пытается сохранить сырой Event (с isTrusted и
// т.п.) как одно-ко-многим payload -> "isTrusted is not allowed". Баг словлен
// 2026-09-22 именно на этом месте — см. свежий perf-picker, там emits объявлен
// сразу и такой проблемы не было.
defineEmits(['input']);

const api = useApi();

const rows = ref([]);          // уже созданные исполнения этого концерта
const loading = ref(false);
const query = ref('');         // строка поиска песни
const results = ref([]);       // результаты автокомплита
const activeIndex = ref(0);    // подсветка в выпадашке
const searchInput = ref(null); // ref на инпут для рефокуса
const error = ref('');         // последняя ошибка сети/валидации — показываем
                                // баннером, но НЕ даём ей уронить весь компонент
                                // (было: необработанное исключение из pick()/
                                // toggleParam()/removeRow() рушило рендер, и
                                // Directus подменял весь интерфейс на
                                // "Unexpected Error" — пропадал и уже
                                // загруженный список. Баг найден 2026-09-22 на
                                // попытке добавить песню, уже стоящую в
                                // сетлисте: RECORD_NOT_UNIQUE по perfs.id).
let searchTimer = null;

// Человекочитаемое сообщение из ответа Directus, с явной веткой для
// повторного добавления той же песни (самый частый случай).
function describeError(e, fallback) {
	const apiError = e?.response?.data?.errors?.[0];
	if (apiError?.extensions?.code === 'RECORD_NOT_UNIQUE') {
		return 'Эта песня уже в сетлисте этого концерта.';
	}
	return apiError?.message || fallback;
}

// Пока концерт не сохранён — нет id, писать исполнения некуда.
const concertSaved = computed(
	() => props.primaryKey != null && props.primaryKey !== '+'
);

const rowFields = [
	'id',
	NUMBER_FIELD,
	`${WORK_FK}.id`,
	...WORK_TITLE_FIELDS.map((f) => `${WORK_FK}.${f}`),
	...PARAM_FIELDS.map((p) => p.key),
];

// watch(immediate) вместо onMounted: primaryKey при монтировании интерфейса
// иногда ещё не готов (плейсхолдер до подгрузки формы), а onMounted стреляет
// строго один раз — при таком раскладе loadRows() тихо выходил по
// concertSaved и список никогда не подгружался, хотя сам инпут ввода
// рендерился нормально (concertSaved — реактивный computed, пересчитывается
// с уже настоящим primaryKey). Баг найден 2026-09-22 сразу после того, как
// починили RECORD_NOT_UNIQUE.
watch(
	() => props.primaryKey,
	(pk) => {
		if (pk != null && pk !== '+') {
			loadRows();
		} else {
			rows.value = [];
		}
	},
	{ immediate: true }
);

async function loadRows() {
	if (!concertSaved.value) return;
	loading.value = true;
	error.value = '';
	try {
		const res = await api.get(`/items/${PERF_COLLECTION}`, {
			params: {
				filter: { [EVENT_FK]: { _eq: props.primaryKey } },
				sort: [NUMBER_FIELD],
				fields: rowFields,
				limit: -1,
			},
		});
		rows.value = res.data.data;
	} catch (e) {
		error.value = describeError(e, 'Не удалось загрузить список исполнений.');
	} finally {
		loading.value = false;
	}
}

// Заголовок песни — та же логика, что в catalogue.html.
function capitalize(s) {
	return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}
function workTitle(work) {
	if (!work) return '—';
	if (work.name) return capitalize(work.fname || work.name);
	return work.fincipit || work.incipit || '—';
}
// Подсказка вторым планом (как "(fincipit)" на сайте) — помогает отличить
// одноимённые/похожие вещи в выпадашке.
function workHint(work) {
	if (!work) return '';
	return work.name ? work.fincipit || '' : '';
}

// Автокомплит: 2+ буквы -> поиск по справочнику. Дебаунс 200мс.
// Намеренно НЕ используем ?search= — у него в этой базе известный баг:
// точное целое слово кириллицей иногда даёт 0 совпадений (см. docs/directus.md,
// раздел «Открытые вопросы»). Вместо этого — явный _icontains по нужным полям.
function onQueryInput() {
	clearTimeout(searchTimer);
	if (query.value.trim().length < 2) {
		results.value = [];
		return;
	}
	searchTimer = setTimeout(searchSongs, 200);
}

async function searchSongs() {
	const q = query.value.trim();
	const filter = {
		_and: [
			...(EXCLUDE_HIDDEN ? [{ hidden: { _neq: true } }] : []),
			{ _or: WORK_TITLE_FIELDS.map((f) => ({ [f]: { _icontains: q } })) },
		],
	};
	try {
		const res = await api.get(`/items/${WORK_COLLECTION}`, {
			params: {
				filter,
				fields: ['id', ...WORK_TITLE_FIELDS],
				sort: ['sort'],
				limit: 10,
			},
		});
		results.value = res.data.data;
		activeIndex.value = 0;
	} catch (e) {
		error.value = describeError(e, 'Не удалось найти песни.');
	}
}

function move(delta) {
	if (!results.value.length) return;
	activeIndex.value =
		(activeIndex.value + delta + results.value.length) % results.value.length;
}

// Enter/выбор: создаём исполнение с FK на песню, чистим строку, фокус остаётся.
// id и num сюда не передаём — их проставляет Flow «Auto perf id».
async function pick(song) {
	const chosen = song ?? results.value[activeIndex.value];
	if (!chosen || !concertSaved.value) return;
	error.value = '';

	// Проверяем по уже загруженному списку, без похода в сеть: та же песня на
	// этом концерте уже есть — id в perfs детерминирован (events_id+works_id),
	// сервер всё равно откажет, но так быстрее и сообщение понятнее.
	const already = rows.value.find((r) => r[WORK_FK]?.id === chosen.id);
	if (already) {
		error.value = `«${workTitle(chosen)}» уже в сетлисте (№${already[NUMBER_FIELD]}).`;
		query.value = '';
		results.value = [];
		searchInput.value?.focus?.();
		return;
	}

	const payload = {
		[EVENT_FK]: props.primaryKey,
		[WORK_FK]: chosen.id,
	};

	try {
		const res = await api.post(`/items/${PERF_COLLECTION}`, payload, {
			params: { fields: rowFields },
		});
		rows.value.push(res.data.data);
		query.value = '';
		results.value = [];
	} catch (e) {
		error.value = describeError(e, 'Не удалось добавить исполнение.');
	} finally {
		searchInput.value?.focus?.();
	}
}

async function toggleParam(row, key) {
	const next = !row[key];
	error.value = '';
	try {
		await api.patch(`/items/${PERF_COLLECTION}/${row.id}`, { [key]: next });
		row[key] = next;
	} catch (e) {
		error.value = describeError(e, 'Не удалось сохранить изменение.');
	}
}

async function removeRow(row) {
	error.value = '';
	try {
		await api.delete(`/items/${PERF_COLLECTION}/${row.id}`);
		rows.value = rows.value.filter((r) => r.id !== row.id);
	} catch (e) {
		error.value = describeError(e, 'Не удалось удалить исполнение.');
	}
}
</script>

<template>
	<div class="setlist-editor">
		<v-notice v-if="!concertSaved" type="info">
			Сначала сохрани концерт — потом добавляй песни.
		</v-notice>

		<template v-else>
			<v-notice v-if="error" type="warning" class="error-notice" closable @close="error = ''">
				{{ error }}
			</v-notice>

			<!-- Уже введённые исполнения -->
			<div v-for="row in rows" :key="row.id" class="perf-row">
				<span class="idx">{{ row[NUMBER_FIELD] }}.</span>
				<span class="title">{{ workTitle(row[WORK_FK]) }}</span>
				<label
					v-for="p in PARAM_FIELDS"
					:key="p.key"
					class="param"
				>
					<v-checkbox
						:model-value="!!row[p.key]"
						@update:model-value="toggleParam(row, p.key)"
					/>
					<span>{{ p.label }}</span>
				</label>
				<v-icon
					name="close"
					clickable
					class="remove"
					@click="removeRow(row)"
				/>
			</div>

			<!-- Строка ввода новой песни -->
			<div class="add-row">
				<input
					ref="searchInput"
					v-model="query"
					class="song-input"
					placeholder="Название песни…"
					@input="onQueryInput"
					@keydown.down.prevent="move(1)"
					@keydown.up.prevent="move(-1)"
					@keydown.enter.prevent="pick()"
					@keydown.esc.prevent="results = []"
				/>
				<ul v-if="results.length" class="dropdown">
					<li
						v-for="(s, i) in results"
						:key="s.id"
						:class="{ active: i === activeIndex }"
						@mousedown.prevent="pick(s)"
					>
						{{ workTitle(s) }}
						<span v-if="workHint(s)" class="hint">({{ workHint(s) }})</span>
					</li>
				</ul>
			</div>

			<v-progress-circular v-if="loading" indeterminate small />
		</template>
	</div>
</template>

<style scoped>
.error-notice {
	margin-bottom: 8px;
}
.perf-row {
	display: flex;
	align-items: center;
	gap: 12px;
	padding: 4px 0;
	border-bottom: 1px solid var(--theme--border-color-subdued, #e4e4e4);
}
.idx { width: 28px; text-align: right; color: var(--theme--foreground-subdued); }
.title { flex: 1; }
.param { display: inline-flex; align-items: center; gap: 4px; }
.remove { color: var(--theme--danger); }
.add-row { position: relative; margin-top: 8px; }
.song-input {
	width: 100%;
	padding: 8px 10px;
	border: 2px solid var(--theme--border-color);
	border-radius: var(--theme--border-radius, 6px);
	background: var(--theme--background);
	color: var(--theme--foreground);
}
.dropdown {
	position: absolute;
	z-index: 10;
	left: 0; right: 0;
	margin: 2px 0 0;
	padding: 0;
	list-style: none;
	background: var(--theme--background);
	border: 1px solid var(--theme--border-color);
	border-radius: var(--theme--border-radius, 6px);
	max-height: 260px;
	overflow-y: auto;
	box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
}
.dropdown li { padding: 8px 10px; cursor: pointer; }
.dropdown li.active,
.dropdown li:hover { background: var(--theme--background-subdued); }
.hint { color: var(--theme--foreground-subdued); font-size: 0.9em; margin-left: 4px; }
</style>
