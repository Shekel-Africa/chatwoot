import { mount } from '@vue/test-utils';
import ResolveAction from './ResolveAction.vue';

const state = vi.hoisted(() => ({ dispatch: vi.fn(), chat: null, agents: [] }));

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', async () => {
  const { computed } = await import('vue');
  return {
    useStore: () => ({ dispatch: state.dispatch }),
    useStoreGetters: () => ({ getSelectedChat: computed(() => state.chat) }),
  };
});
vi.mock('dashboard/composables/useAgentsList', async () => {
  const { computed } = await import('vue');
  return {
    useAgentsList: () => ({
      assignableAgents: computed(() => state.agents),
    }),
  };
});
vi.mock('dashboard/composables/emitter', () => ({ useEmitter: vi.fn() }));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));
vi.mock('dashboard/composables/useConversationRequiredAttributes', () => ({
  useConversationRequiredAttributes: () => ({
    checkMissingAttributes: () => ({ hasMissing: false, missing: [] }),
  }),
}));
vi.mock('dashboard/modules/command-bar/openCommandBar', () => ({
  openCommandBar: vi.fn(),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('@vueuse/core', async () => {
  const { ref: createRef } = await import('vue');
  return {
    useToggle: () => {
      const on = createRef(false);
      const toggle = value => {
        on.value = value === undefined ? !on.value : value;
      };
      return [on, toggle];
    },
  };
});

const SHAILOQ = {
  id: 7,
  name: 'Shailoq Staging Bot',
  assignee_type: 'AgentBot',
};
const PERSON = { id: 1, name: 'A Person', assignee_type: 'User' };

const buttonStub = {
  props: ['label'],
  emits: ['click'],
  template:
    '<button :data-label="label" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountWith = (status, agents = [PERSON, SHAILOQ]) => {
  state.chat = { id: 42, status, custom_attributes: {} };
  state.agents = agents;
  state.dispatch.mockReset().mockResolvedValue();
  return mount(ResolveAction, {
    global: {
      directives: { 'on-clickaway': {} },
      stubs: {
        Button: buttonStub,
        ButtonGroup: { template: '<div><slot /></div>' },
        WootDropdownMenu: { template: '<ul><slot /></ul>' },
        WootDropdownItem: { template: '<li><slot /></li>' },
        WootDropdownHeader: {
          props: ['title'],
          template: '<li data-testid="header">{{ title }}</li>',
        },
        WootDropdownDivider: { template: '<li data-testid="divider" />' },
        ConversationResolveAttributesModal: true,
      },
    },
  });
};

const openMenu = async wrapper => {
  await wrapper.findAll('button').at(-1).trigger('click');
};

const itemLabels = wrapper =>
  wrapper.findAll('li button').map(b => b.attributes('data-label'));

describe('ResolveAction hand back to a bot', () => {
  it('lists the bots of the inbox under their own heading, not people', async () => {
    const wrapper = mountWith('open');
    await openMenu(wrapper);
    expect(wrapper.find('[data-testid="header"]').text()).toBe(
      'CONVERSATION.RESOLVE_DROPDOWN.HAND_BACK_TITLE'
    );
    const bots = wrapper.findAll('[data-testid="hand-back-to-bot"]');
    expect(bots.map(b => b.attributes('data-label'))).toEqual([SHAILOQ.name]);
  });

  it('leaves Snooze and Mark as pending as they were', async () => {
    const wrapper = mountWith('open');
    await openMenu(wrapper);
    const labels = itemLabels(wrapper);
    expect(labels).toContain('CONVERSATION.RESOLVE_DROPDOWN.SNOOZE_UNTIL');
    expect(labels).toContain('CONVERSATION.RESOLVE_DROPDOWN.MARK_PENDING');

    await wrapper
      .find('[data-label="CONVERSATION.RESOLVE_DROPDOWN.MARK_PENDING"]')
      .trigger('click');
    expect(state.dispatch).toHaveBeenCalledWith('toggleStatus', {
      conversationId: 42,
      status: 'pending',
      snoozedUntil: undefined,
    });
  });

  it('assigns the chosen bot to the chat in one click', async () => {
    const wrapper = mountWith('open');
    await openMenu(wrapper);
    await wrapper.find('[data-bot-id="7"]').trigger('click');
    expect(state.dispatch).toHaveBeenCalledTimes(1);
    expect(state.dispatch).toHaveBeenCalledWith('assignAgent', {
      conversationId: 42,
      agentId: 7,
      assigneeType: 'AgentBot',
    });
  });

  it('lets the agent pick between several bots', async () => {
    const other = { id: 9, name: 'Other Bot', assignee_type: 'AgentBot' };
    const wrapper = mountWith('open', [PERSON, SHAILOQ, other]);
    await openMenu(wrapper);
    expect(
      wrapper
        .findAll('[data-testid="hand-back-to-bot"]')
        .map(b => b.attributes('data-label'))
    ).toEqual([SHAILOQ.name, other.name]);
    await wrapper.find('[data-bot-id="9"]').trigger('click');
    expect(state.dispatch).toHaveBeenCalledWith('assignAgent', {
      conversationId: 42,
      agentId: 9,
      assigneeType: 'AgentBot',
    });
  });

  it('is also offered on a resolved chat', async () => {
    const wrapper = mountWith('resolved');
    await openMenu(wrapper);
    expect(wrapper.find('[data-bot-id="7"]').exists()).toBe(true);
  });

  it('shows no bot section when the inbox has no bot', async () => {
    const wrapper = mountWith('open', [PERSON]);
    await openMenu(wrapper);
    expect(wrapper.find('[data-testid="header"]').exists()).toBe(false);
    expect(wrapper.find('[data-testid="hand-back-to-bot"]').exists()).toBe(
      false
    );
  });

  it.each(['pending', 'snoozed'])(
    'is offered on a %s chat, with only the bots in the menu',
    async status => {
      const wrapper = mountWith(status);
      await openMenu(wrapper);
      expect(itemLabels(wrapper)).toEqual([SHAILOQ.name]);
      expect(wrapper.find('[data-testid="divider"]').exists()).toBe(false);

      await wrapper.find('[data-bot-id="7"]').trigger('click');
      expect(state.dispatch).toHaveBeenCalledWith('assignAgent', {
        conversationId: 42,
        agentId: 7,
        assigneeType: 'AgentBot',
      });
    }
  );

  it.each(['pending', 'snoozed'])(
    'has no dropdown on a %s chat when the inbox has no bot',
    status => {
      const wrapper = mountWith(status, [PERSON]);
      // Only the Open button, no chevron.
      expect(wrapper.findAll('button')).toHaveLength(1);
    }
  );
});
