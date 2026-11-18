import {
  getLoadingStatus,
  parseAPIErrorResponse,
  setLoadingStatus,
  throwErrorMessage,
  parseLinearAPIErrorResponse,
  setAuthCredentials,
} from '../api';
import Cookies from 'js-cookie';

describe('#getLoadingStatus', () => {
  it('returns correct status', () => {
    expect(getLoadingStatus({ fetchAPIloadingStatus: true })).toBe(true);
  });
});

describe('#setLoadingStatus', () => {
  it('set correct status', () => {
    const state = { fetchAPIloadingStatus: true };
    setLoadingStatus(state, false);
    expect(state.fetchAPIloadingStatus).toBe(false);
  });
});

describe('#parseAPIErrorResponse', () => {
  it('returns correct values', () => {
    expect(
      parseAPIErrorResponse({
        response: { data: { message: 'Error Message [message]' } },
      })
    ).toBe('Error Message [message]');

    expect(
      parseAPIErrorResponse({
        response: { data: { error: 'Error Message [error]' } },
      })
    ).toBe('Error Message [error]');

    expect(parseAPIErrorResponse('Error: 422 Failed')).toBe(
      'Error: 422 Failed'
    );
  });
});

describe('#throwErrorMessage', () => {
  it('throws correct error', () => {
    const errorFn = function throwErrorMessageFn() {
      throwErrorMessage({
        response: { data: { message: 'Error Message [message]' } },
      });
    };
    expect(errorFn).toThrow('Error Message [message]');
  });
});

describe('#parseLinearAPIErrorResponse', () => {
  it('returns correct values', () => {
    expect(
      parseLinearAPIErrorResponse(
        {
          response: {
            data: {
              error: {
                errors: [
                  {
                    message: 'Error Message [message]',
                  },
                ],
              },
            },
          },
        },
        'Default Message'
      )
    ).toBe('Error Message [message]');
  });
});

// S20-4853: the session cookie must live as long as the token. Rounding the
// lifespan down to whole days made a 12-hour staff session (the fork's
// SHEKEL_SESSION_LIFESPAN_HOURS default) expire the cookie the moment it was set.
describe('#setAuthCredentials', () => {
  const responseExpiringIn = seconds => ({
    headers: {
      'access-token': 'token',
      client: 'client',
      uid: 'uid',
      expiry: String(Math.floor(Date.now() / 1000) + seconds),
    },
    data: { data: { id: 1 } },
  });

  beforeEach(() => vi.spyOn(Cookies, 'set'));
  afterEach(() => vi.restoreAllMocks());

  it.each([
    ['12 hours', 12 * 3600],
    ['2 months', 61 * 24 * 3600],
  ])('expires the session cookie with the token (%s)', (_, seconds) => {
    const response = responseExpiringIn(seconds);
    setAuthCredentials(response);

    const [name, , options] = Cookies.set.mock.calls.find(
      ([cookie]) => cookie === 'cw_d_session_info'
    );
    expect(name).toBe('cw_d_session_info');
    expect(options.expires).toBeInstanceOf(Date);
    expect(options.expires.getTime()).toBe(
      Number(response.headers.expiry) * 1000
    );
  });
});
