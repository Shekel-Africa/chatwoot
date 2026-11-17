<script setup>
// Shekel fork: starts staff sign-in through authentication-api (admin realm).
// OmniAuth only accepts the request phase as a POST carrying the Rails CSRF
// token (omniauth-rails_csrf_protection), so this is a form, not a link.
const SHEKEL_OIDC_REQUEST_PATH = '/omniauth/shekel';

const csrfToken =
  document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') ||
  '';
</script>

<template>
  <form method="post" :action="SHEKEL_OIDC_REQUEST_PATH" class="flex flex-col">
    <input type="hidden" name="authenticity_token" :value="csrfToken" />
    <button
      type="submit"
      data-testid="shekel-oidc-login"
      class="inline-flex justify-center w-full px-4 py-3 bg-n-background dark:bg-n-solid-3 items-center rounded-md shadow-sm ring-1 ring-inset ring-n-container dark:ring-n-container focus:outline-offset-0 hover:bg-n-alpha-2 dark:hover:bg-n-alpha-2"
    >
      <span class="i-lucide-shield-check size-5 text-n-slate-11" />
      <span class="ml-2 text-base font-medium text-n-slate-12">
        {{ $t('LOGIN.OAUTH.SHEKEL_LOGIN') }}
      </span>
    </button>
  </form>
</template>
