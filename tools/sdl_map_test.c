#include <SDL2/SDL.h>
#include <stdio.h>
#include <string.h>

static const char *MAP =
"0300703ba32c00002010000004040000,DJI C5,a:b0,b:b1,x:b2,y:b3,back:b4,start:b5,"
"leftshoulder:b6,rightshoulder:b7,guide:b8,leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,platform:Mac OS X,";

int main(void){
    SDL_Init(SDL_INIT_JOYSTICK|SDL_INIT_GAMECONTROLLER);
    int n = SDL_NumJoysticks();
    printf("joysticks=%d\n", n);
    if (n<1) return 0;
    printf("BEFORE mapping: isGameController=%d  (need 1)\n", SDL_IsGameController(0));
    int rc = SDL_GameControllerAddMapping(MAP);
    printf("AddMapping rc=%d (%s)\n", rc, rc<0?SDL_GetError():"ok");
    SDL_PumpEvents();
    int gc = SDL_IsGameController(0);
    printf("AFTER  mapping: isGameController=%d\n", gc);
    if (!gc) { SDL_Quit(); return 0; }
    SDL_GameController *c = SDL_GameControllerOpen(0);
    if(!c){ printf("GameControllerOpen failed: %s\n", SDL_GetError()); SDL_Quit(); return 0; }
    printf("opened as GameController: \"%s\"\n", SDL_GameControllerName(c));
    SDL_GameControllerUpdate();
    printf("  leftx  = %6d\n", SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_LEFTX));
    printf("  lefty  = %6d\n", SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_LEFTY));
    printf("  rightx = %6d\n", SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_RIGHTX));
    printf("  righty = %6d\n", SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_RIGHTY));
    printf("  trigger= %6d\n", SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_TRIGGERLEFT));
    SDL_GameControllerClose(c); SDL_Quit(); return 0;
}
