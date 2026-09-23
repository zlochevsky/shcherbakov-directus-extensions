import InterfaceComponent from './interface.vue';

// Регистрация кастомного O2M-интерфейса для Directus 11.x.
// Вешается на alias-поле связи "исполнения" в коллекции концертов.
export default {
	id: 'setlist-editor',
	name: 'Редактор сетлиста',
	icon: 'queue_music',
	description:
		'Инлайн-ввод исполнений с автокомплитом песни по названию. Пишет FK на песню (id), не открывая модалку.',
	component: InterfaceComponent,
	types: ['alias'],
	localTypes: ['o2m'],
	group: 'relational',
	relational: true,
};
