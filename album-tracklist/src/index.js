import InterfaceComponent from './interface.vue';

// O2M-интерфейс на alias-поле sets.entries (связь sets_entries.sets_id -> sets).
// Показывает треклист альбома и добавляет в него УЖЕ СУЩЕСТВУЮЩИЕ исполнения.
export default {
	id: 'album-tracklist',
	name: 'Треклист альбома',
	icon: 'album',
	description:
		'Треклист альбома: поиск существующих исполнений по id/году события/названию песни, номер и сторона в строке. Пишет sets_entries напрямую.',
	component: InterfaceComponent,
	types: ['alias'],
	localTypes: ['o2m'],
	group: 'relational',
	relational: true,
};
