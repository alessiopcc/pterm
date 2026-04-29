#ifndef PTERM_WIN_TOAST_H
#define PTERM_WIN_TOAST_H

#ifdef __cplusplus
extern "C" {
#endif

/* Register PTerm with the OS as a toast-capable app and set the process AUMID.
   Creates a Start-menu shortcut at %APPDATA%\Microsoft\Windows\Start Menu\
   Programs\<display>.lnk with PKEY_AppUserModel_ID set, idempotently.
   Returns 0 on success, non-zero HRESULT on failure. */
int pterm_notify_init(const char *aumid_utf8, const char *display_name_utf8);

/* Show a Windows 10/11 toast notification via WinRT. Fire and forget.
   Returns 0 on success, non-zero on failure. play_sound: 0=silent, 1=default. */
int pterm_notify_send(const char *title_utf8, const char *body_utf8, int play_sound);

#ifdef __cplusplus
}
#endif

#endif
