/* Shim providing SDL_TryLockJoysticks for Steam clients built against
 * Valve's internal SDL fork. Upstream SDL 3.4.4 does not export this
 * symbol, so steamui.so fails to load against an unmodified upstream SDL.
 *
 * Implementation: forward to SDL_LockJoysticks (always succeeds -> return 1).
 */
extern void SDL_LockJoysticks(void);

int SDL_TryLockJoysticks(void)
{
    SDL_LockJoysticks();
    return 1;
}
