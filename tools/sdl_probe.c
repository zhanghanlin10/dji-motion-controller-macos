#include <SDL2/SDL.h>
#include <stdio.h>
int main(void){
    if(SDL_Init(SDL_INIT_JOYSTICK|SDL_INIT_GAMECONTROLLER)!=0){printf("SDL_Init fail: %s\n",SDL_GetError());return 1;}
    int n=SDL_NumJoysticks();
    printf("SDL %d.%d.%d  joysticks=%d\n", SDL_MAJOR_VERSION,SDL_MINOR_VERSION,SDL_PATCHLEVEL, n);
    for(int i=0;i<n;i++){
        printf("  [%d] name=\"%s\"  isGameController=%d\n", i, SDL_JoystickNameForIndex(i), SDL_IsGameController(i));
        SDL_Joystick *j=SDL_JoystickOpen(i);
        if(!j){printf("      open failed: %s\n",SDL_GetError());continue;}
        printf("      axes=%d buttons=%d hats=%d\n",SDL_JoystickNumAxes(j),SDL_JoystickNumButtons(j),SDL_JoystickNumHats(j));
        for(int a=0;a<SDL_JoystickNumAxes(j);a++) printf("      axis[%d]=%d\n",a,SDL_JoystickGetAxis(j,a));
        SDL_JoystickClose(j);
    }
    SDL_Quit(); return 0;
}
