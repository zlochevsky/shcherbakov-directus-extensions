<script setup>
import { ref, nextTick, onMounted, watch } from 'vue';
import { useApi } from '@directus/extensions-sdk';

/* ─────────────────────────────────────────────────────────────
   M2O-пикер существующего исполнения (perfs) по названию песни.
   Сестра setlist-editor (events.songs_performed), но проще:
   ничего не создаёт, только ищет и пишет FK в текущее поле
   (напр. sets_entries.perfs_id). Схема сверена с /fields/perfs
   и /fields/sets_entries 2026-09-22.
   ───────────────────────────────────────────────────────────── */
const PERF_COLLECTION = 'perfs';
const WORK_FK = 'works_id';   // perfs.works_id -> works
const EVENT_FK = 'events_id'; // perfs.events_id -> events, для разрешения
                               // неоднозначности между разными исполнениями
                               // одной и той же песни
const WORK_TITLE_FIELDS = ['name', 'fname', 'incipit', 'fincipit', 'sort'];
/* ───────────────────────────────────────────────────────────── */

const props = defineProps({
	value: { type: [String, Number], default: null },
	disabled: { type: Boolean, default: false },
});
const emit = defineEmits(['input']);

const api = useApi();

const editing = ref(false);     // true — показан инпут поиска вместо карточки значения
const currentLabel = ref('');   // подпись выбранного значения
const labelLoading = ref(false);
const query = ref('');
const results = ref([]);
const activeIndex = ref(0);
const loading = ref(false);
const searchInput = ref(null);
let searchTimer = null;
let blurTimer = null;

function capitalize(s) {
	return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}
// Та же логика заголовка песни, что в setlist-editor и в catalogue.html.
function workTitle(work) {
	if (!work) return '—';
	if (work.name) return capitalize(work.fname || work.name);
	return work.fincipit || work.incipit || '—';
}

async function loadCurrentLabel() {
	if (!props.value) {
		currentLabel.value = '';
		return;
	}
	labelLoading.value = true;
	try {
		const res = await api.get(`/items/${PERF_COLLECTION}/${props.value}`, {
			params: {
				fields: ['id', EVENT_FK, ...WORK_TITLE_FIELDS.map((f) => `${WORK_FK}.${f}`)],
			},
		});
		const p = res.data.data;
		currentLabel.value = p ? labelFor(p) : `(не найдено: ${props.value})`;
	} catch {
		currentLabel.value = `(ошибка загрузки: ${props.value})`;
	} finally {
		labelLoading.value = false;
	}
}

function labelFor(perf) {
	const title = workTitle(perf[WORK_FK]);
	return perf[EVENT_FK] ? `${title} — ${perf[EVENT_FK]}` : title;
}

onMounted(loadCurrentLabel);
watch(() => props.value, loadCurrentLabel);

function startEdit() {
	if (props.disabled) return;
	editing.value = true;
	query.value = '';
	results.value = [];
	nextTick(() => searchInput.value?.focus?.());
}

function cancelEdit() {
	clearTimeout(blurTimer);
	editing.value = false;
	query.value = '';
	results.value = [];
}

function onBlur() {
	// Даём клику по строке результата (mousedown.prevent) отработать раньше blur.
	blurTimer = setTimeout(cancelEdit, 150);
}

function onQueryInput() {
	clearTimeout(searchTimer);
	if (query.value.trim().length < 2) {
		results.value = [];
		return;
	}
	searchTimer = setTimeout(searchPerfs, 200);
}

// Ищем по полям названия песни через связь works_id, а также по самому
// id исполнения (там зашит слаг события, напр. "s2026-kakvizve") — так
// можно набрать часть кода концерта и сразу сузить варианты, если песня
// исполнялась не раз.
async function searchPerfs() {
	const q = query.value.trim();
	loading.value = true;
	try {
		const filter = {
			_or: [
				...WORK_TITLE_FIELDS.map((f) => ({ [WORK_FK]: { [f]: { _icontains: q } } })),
				{ id: { _icontains: q } },
			],
		};
		const res = await api.get(`/items/${PERF_COLLECTION}`, {
			params: {
				filter,
				fields: ['id', EVENT_FK, ...WORK_TITLE_FIELDS.map((f) => `${WORK_FK}.${f}`)],
				sort: ['-id'],
				limit: 15,
			},
		});
		results.value = res.data.data;
		activeIndex.value = 0;
	} finally {
		loading.value = false;
	}
}

function move(delta) {
	if (!results.value.length) return;
	activeIndex.value = (activeIndex.value + delta + results.value.length) % results.value.length;
}

function pick(perf) {
	const chosen = perf ?? results.value[activeIndex.value];
	if (!chosen) return;
	clearTimeout(blurTimer);
	emit('input', chosen.id);
	currentLabel.value = labelFor(chosen);
	editing.value = false;
	query.value = '';
	results.value = [];
}

function clearValue() {
	emit('input', null);
	currentLabel.value = '';
}
</script>

<template>
	<div class="perf-picker">
		<template v-if="!editing">
			<div v-if="value" class="value-card">
				<span class="label">{{ labelLoading ? '…' : currentLabel }}</span>
				<v-icon
					v-if="!disabled"
					name="edit"
					clickable
					small
					class="action"
					@click="startEdit"
				/>
				<v-icon
					v-if="!disabled"
					name="close"
					clickable
					small
					class="action"
					@click="clearValue"
				/>
			</div>
			<button
				v-else
				type="button"
				class="pick-btn"
				:disabled="disabled"
				@click="startEdit"
			>
				Выбрать исполнение…
			</button>
		</template>

		<template v-else>
			<div class="search-wrap">
				<input
					ref="searchInput"
					v-model="query"
					class="song-input"
					placeholder="Название песни или id исполнения…"
					@input="onQueryInput"
					@blur="onBlur"
					@keydown.down.prevent="move(1)"
					@keydown.up.prevent="move(-1)"
					@keydown.enter.prevent="pick()"
					@keydown.esc.prevent="cancelEdit"
				/>
				<v-progress-circular v-if="loading" indeterminate small class="spinner" />
				<ul v-if="results.length" class="dropdown">
					<li
						v-for="(r, i) in results"
						:key="r.id"
						:class="{ active: i === activeIndex }"
						@mousedown.prevent="pick(r)"
					>
						{{ workTitle(r[WORK_FK]) }}
						<span class="hint">{{ r[EVENT_FK] }} · {{ r.id }}</span>
					</li>
				</ul>
			</div>
		</template>
	</div>
</template>

<style scoped>
.value-card {
	display: flex;
	align-items: center;
	gap: 8px;
	padding: 8px 10px;
	border: 2px solid var(--theme--border-color);
	border-radius: var(--theme--border-radius, 6px);
	background: var(--theme--background);
}
.value-card .label { flex: 1; }
.action { color: var(--theme--foreground-subdued); }
.pick-btn {
	width: 100%;
	text-align: left;
	padding: 8px 10px;
	border: 2px dashed var(--theme--border-color);
	border-radius: var(--theme--border-radius, 6px);
	background: transparent;
	color: var(--theme--foreground-subdued);
	cursor: pointer;
}
.search-wrap { position: relative; }
.song-input {
	width: 100%;
	padding: 8px 10px;
	border: 2px solid var(--theme--primary, var(--theme--border-color));
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
	max-height: 260px;
	overflow-y: auto;
	box-shadow: 0 4px 12px rgba(0, 0, 0, 0.12);
}
.dropdown li { padding: 8px 10px; cursor: pointer; }
.dropdown li.active,
.dropdown li:hover { background: var(--theme--background-subdued); }
.hint { color: var(--theme--foreground-subdued); font-size: 0.9em; margin-left: 6px; }
</style>
