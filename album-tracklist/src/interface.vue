<script setup>
import { ref, computed, watch } from 'vue';
import { useApi } from '@directus/extensions-sdk';

/* ─────────────────────────────────────────────────────────────
   Треклист альбома (sets) поверх sets_entries. Сестра setlist-editor
   и perf-picker: как и они, пишет через api.* напрямую (кнопка Save формы
   при этом не нужна), но не создаёт исполнения, а выбирает существующие.
   id записи и её номер (если не передан) проставляет Flow
   «Auto set entry id». Номер в строке можно править, id при этом не меняется
   (id «раз и навсегда»).
   ───────────────────────────────────────────────────────────── */
const ENTRY_COLLECTION = 'sets_entries';
const SET_FK = 'sets_id';
const PERF_FK = 'perfs_id';
const PERF_COLLECTION = 'perfs';
const WORK_FK = 'works_id';
const EVENT_FK = 'events_id';
const NUMBER_FIELD = 'num';
const SIDE_FIELD = 'side';
const SIDES = ['A', 'B'];
const WORK_TITLE_FIELDS = ['name', 'fname', 'incipit', 'fincipit', 'sort'];
const EVENT_FIELDS = ['id', 'date', 'year', 'town'];
/* ───────────────────────────────────────────────────────────── */

const props = defineProps({
	value: { type: [Array, Object], default: null },
	collection: { type: String, default: null },
	field: { type: String, default: null },
	primaryKey: { type: [String, Number], default: null },
});
// См. комментарий в setlist-editor: без декларации Directus-овский @input
// прилипает к корневому <div> как DOM-листенер.
defineEmits(['input']);

const api = useApi();

const rows = ref([]);
const loading = ref(false);
const error = ref('');
const query = ref('');
const results = ref([]);
const activeIndex = ref(0);
const searching = ref(false);
const searchInput = ref(null);
let searchTimer = null;

const saved = computed(() => props.primaryKey != null && props.primaryKey !== '+');
const addedPerfIds = computed(() => new Set(rows.value.map((r) => r[PERF_FK]?.id)));

const entryFields = [
	'id',
	NUMBER_FIELD,
	SIDE_FIELD,
	`${PERF_FK}.id`,
	...WORK_TITLE_FIELDS.map((f) => `${PERF_FK}.${WORK_FK}.${f}`),
	...EVENT_FIELDS.map((f) => `${PERF_FK}.${EVENT_FK}.${f}`),
];

function describeError(e, fallback) {
	const apiError = e?.response?.data?.errors?.[0];
	if (apiError?.extensions?.code === 'RECORD_NOT_UNIQUE') return 'Такая запись уже есть в альбоме.';
	return apiError?.message || fallback;
}

function capitalize(s) {
	return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}
function workTitle(work) {
	if (!work) return '—';
	if (work.name) return capitalize(work.fname || work.name);
	return work.fincipit || work.incipit || '—';
}
function eventLabel(ev) {
	if (!ev) return '';
	return [ev.id, ev.town].filter(Boolean).join(' · ');
}

watch(
	() => props.primaryKey,
	(pk) => {
		if (pk != null && pk !== '+') loadRows();
		else rows.value = [];
	},
	{ immediate: true }
);

function sortRows() {
	rows.value.sort((a, b) => (a[NUMBER_FIELD] ?? 0) - (b[NUMBER_FIELD] ?? 0));
}

async function loadRows() {
	if (!saved.value) return;
	loading.value = true;
	error.value = '';
	try {
		const res = await api.get(`/items/${ENTRY_COLLECTION}`, {
			params: {
				filter: { [SET_FK]: { _eq: props.primaryKey } },
				sort: [NUMBER_FIELD],
				fields: entryFields,
				limit: -1,
			},
		});
		rows.value = res.data.data;
	} catch (e) {
		error.value = describeError(e, 'Не удалось загрузить треклист.');
	} finally {
		loading.value = false;
	}
}

/* Поиск исполнений. Строка режется на слова, каждое слово должно найтись
   в id исполнения, в году события или в названии песни (слова связаны «И»):
   «2003 кибитка», «L2003-04 бостон», «s2026». Явный _icontains, не ?search=
   (баг с кириллицей, см. setlist-editor). */
function onQueryInput() {
	clearTimeout(searchTimer);
	const q = query.value.trim();
	if (q.length < 2 && !/^\d+$/.test(q)) {
		results.value = [];
		return;
	}
	searchTimer = setTimeout(search, 200);
}

function buildFilter(q) {
	const tokens = q.split(/\s+/).filter(Boolean);
	return {
		_and: tokens.map((t) => ({
			_or: [
				{ id: { _icontains: t } },
				...(/^\d{4}$/.test(t) ? [{ [EVENT_FK]: { year: { _eq: Number(t) } } }] : []),
				...WORK_TITLE_FIELDS.map((f) => ({ [WORK_FK]: { [f]: { _icontains: t } } })),
			],
		})),
	};
}

async function search() {
	const q = query.value.trim();
	if (!q) return;
	searching.value = true;
	try {
		const res = await api.get(`/items/${PERF_COLLECTION}`, {
			params: {
				filter: buildFilter(q),
				fields: [
					'id',
					NUMBER_FIELD,
					...WORK_TITLE_FIELDS.map((f) => `${WORK_FK}.${f}`),
					...EVENT_FIELDS.map((f) => `${EVENT_FK}.${f}`),
				],
				sort: [`-${EVENT_FK}.date`, NUMBER_FIELD],
				limit: 30,
			},
		});
		results.value = res.data.data;
		activeIndex.value = 0;
	} catch (e) {
		error.value = describeError(e, 'Не удалось найти исполнения.');
	} finally {
		searching.value = false;
	}
}

function move(delta) {
	if (!results.value.length) return;
	activeIndex.value = (activeIndex.value + delta + results.value.length) % results.value.length;
}

// Добавление: id и (без num) номер проставляет Flow. Сторону наследуем от
// последней строки. Выпадашка остаётся открытой — можно брать подряд
// несколько исполнений одного концерта; уже добавленные помечены.
async function pick(perf) {
	const chosen = perf ?? results.value[activeIndex.value];
	if (!chosen || !saved.value) return;
	error.value = '';
	if (addedPerfIds.value.has(chosen.id)) {
		error.value = `«${workTitle(chosen[WORK_FK])}» (${chosen[EVENT_FK]?.id ?? chosen.id}) уже в альбоме.`;
		return;
	}
	const last = rows.value[rows.value.length - 1];
	const payload = { [SET_FK]: props.primaryKey, [PERF_FK]: chosen.id };
	if (last?.[SIDE_FIELD]) payload[SIDE_FIELD] = last[SIDE_FIELD];
	try {
		const res = await api.post(`/items/${ENTRY_COLLECTION}`, payload, { params: { fields: entryFields } });
		rows.value.push(res.data.data);
		sortRows();
		if (activeIndex.value < results.value.length - 1) activeIndex.value += 1;
	} catch (e) {
		error.value = describeError(e, 'Не удалось добавить исполнение.');
	} finally {
		searchInput.value?.focus?.();
	}
}

async function saveNum(row, ev) {
	const n = parseInt(ev.target.value, 10);
	if (!Number.isInteger(n) || n < 1) {
		ev.target.value = row[NUMBER_FIELD];
		return;
	}
	if (n === row[NUMBER_FIELD]) return;
	error.value = '';
	try {
		await api.patch(`/items/${ENTRY_COLLECTION}/${row.id}`, { [NUMBER_FIELD]: n });
		row[NUMBER_FIELD] = n;
		sortRows();
	} catch (e) {
		ev.target.value = row[NUMBER_FIELD];
		error.value = describeError(e, 'Не удалось изменить номер.');
	}
}

async function saveSide(row, ev) {
	const v = ev.target.value || null;
	error.value = '';
	try {
		await api.patch(`/items/${ENTRY_COLLECTION}/${row.id}`, { [SIDE_FIELD]: v });
		row[SIDE_FIELD] = v;
	} catch (e) {
		ev.target.value = row[SIDE_FIELD] ?? '';
		error.value = describeError(e, 'Не удалось изменить сторону.');
	}
}

async function removeRow(row) {
	error.value = '';
	try {
		await api.delete(`/items/${ENTRY_COLLECTION}/${row.id}`);
		rows.value = rows.value.filter((r) => r.id !== row.id);
	} catch (e) {
		error.value = describeError(e, 'Не удалось убрать исполнение.');
	}
}
</script>

<template>
	<div class="album-tracklist">
		<v-notice v-if="!saved" type="info">Сначала сохрани альбом — потом добавляй исполнения.</v-notice>

		<template v-else>
			<v-notice v-if="error" type="warning" class="error-notice" closable @close="error = ''">
				{{ error }}
			</v-notice>

			<div v-for="row in rows" :key="row.id" class="entry-row">
				<input
					class="num"
					type="number"
					min="1"
					:value="row[NUMBER_FIELD]"
					title="Номер в альбоме"
					@change="saveNum(row, $event)"
					@keydown.enter.prevent="$event.target.blur()"
				/>
				<select class="side" :value="row[SIDE_FIELD] ?? ''" title="Сторона" @change="saveSide(row, $event)">
					<option value="">—</option>
					<option v-for="s in SIDES" :key="s" :value="s">{{ s }}</option>
				</select>
				<span class="title">{{ workTitle(row[PERF_FK]?.[WORK_FK]) }}</span>
				<span class="hint">{{ eventLabel(row[PERF_FK]?.[EVENT_FK]) || row[PERF_FK]?.id }}</span>
				<v-icon name="close" clickable class="remove" @click="removeRow(row)" />
			</div>

			<div class="add-row">
				<input
					ref="searchInput"
					v-model="query"
					class="song-input"
					placeholder="Добавить исполнение: id / год события / название песни…"
					@input="onQueryInput"
					@keydown.down.prevent="move(1)"
					@keydown.up.prevent="move(-1)"
					@keydown.enter.prevent="pick()"
					@keydown.esc.prevent="results = []"
				/>
				<v-progress-circular v-if="searching" indeterminate small class="spinner" />
				<ul v-if="results.length" class="dropdown">
					<li
						v-for="(r, i) in results"
						:key="r.id"
						:class="{ active: i === activeIndex, added: addedPerfIds.has(r.id) }"
						@mousedown.prevent="pick(r)"
					>
						<span v-if="addedPerfIds.has(r.id)" class="mark">✓</span>
						{{ workTitle(r[WORK_FK]) }}
						<span class="hint">{{ eventLabel(r[EVENT_FK]) }} · {{ r.id }}</span>
					</li>
				</ul>
			</div>

			<v-progress-circular v-if="loading" indeterminate small />
		</template>
	</div>
</template>

<style scoped>
.error-notice { margin-bottom: 8px; }
.entry-row {
	display: flex;
	align-items: center;
	gap: 10px;
	padding: 4px 0;
	border-bottom: 1px solid var(--theme--border-color-subdued, #e4e4e4);
}
.num, .side {
	padding: 4px 6px;
	border: 1px solid var(--theme--border-color);
	border-radius: var(--theme--border-radius, 6px);
	background: var(--theme--background);
	color: var(--theme--foreground);
}
.num { width: 64px; }
.side { width: 60px; }
.title { flex: 1; }
.hint { color: var(--theme--foreground-subdued); font-size: 0.9em; margin-left: 4px; }
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
.spinner { position: absolute; right: 10px; top: 10px; }
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
	max-height: 320px;
	overflow-y: auto;
	box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
}
.dropdown li { padding: 8px 10px; cursor: pointer; }
.dropdown li.active, .dropdown li:hover { background: var(--theme--background-subdued); }
.dropdown li.added { color: var(--theme--foreground-subdued); }
.mark { color: var(--theme--success, green); margin-right: 4px; }
</style>
