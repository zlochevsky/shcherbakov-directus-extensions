import InterfaceComponent from './interface.vue';

// M2O-интерфейс для связи "существующее исполнение" (perfs.id), напр.
// sets_entries.perfs_id. В отличие от setlist-editor ничего не создаёт —
// только ищет и пишет FK на уже существующую запись perfs.
export default {
	id: 'perf-picker',
	name: 'Выбор исполнения',
	icon: 'search',
	description:
		'Инлайн-поиск существующего исполнения по названию песни. Пишет FK (perfs.id) без модалки и чекбоксов.',
	component: InterfaceComponent,
	types: ['string'],
	localTypes: ['m2o'],
	group: 'relational',
	relational: true,
	options: null,
};
