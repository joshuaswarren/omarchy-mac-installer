#define AUTHORIZATION_TIMEOUT_SECONDS 2
#include "../Native/Authorization.c"
#include <assert.h>
#include <stdio.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
static char latest[LOG_LIMIT*10+64];
static void password_mode(void) {
    struct termios term;
    assert(tcgetattr(STDIN_FILENO,&term)==0);
    term.c_lflag &= ~(ECHO|ECHONL);
    assert(tcsetattr(STDIN_FILENO,TCSAFLUSH,&term)==0);
}
static void capture(const char *text, void *context) {
    (void)context;
    assert(!strstr(text,"fixture-password"));
    assert(!strstr(text,"fixture-pass"));
    snprintf(latest,sizeof(latest),"%s",text);
}
int main(int argc, char **argv)
{
    if (argc > 1) {
        if (!strcmp(argv[1], "--grandchild-holds-terminal")) {
            signal(SIGHUP,SIG_IGN);
            pid_t helper=fork();
            if(helper<0)return 30;
            if(!helper) { sleep(20); _exit(31); }
            printf("helper-pid:%ld\n",(long)helper);fflush(stdout);
            return 0;
        }
        if (!strcmp(argv[1], "--timeout")) { sleep(20);return 32; }
        if (!strcmp(argv[1], "--fd-check")) {
            for(int fd=3;fd<64;fd++)if(fcntl(fd,F_GETFD)>=0)return 33;
            return 0;
        }
        char user[128], password[128], confirmation[16];
        if (!strcmp(argv[1], "--getpass")) {
            alarm(3);
            fputs("Username: ", stderr); fflush(stderr);
            if (!fgets(user,sizeof(user),stdin)) return 20;
            const char *secret=getpass("Password: ");
            return strcmp(user,"fixture-user\n") || !secret || strcmp(secret,"fixture-password") ? 21 : 0;
        }

        if (!strncmp(argv[1], "--native-confirm", 16)) {
            const char *prompt="Are you sure you want to do this? (enter y or n)\r\n";
            alarm(3); /* Bound the regression when an old matcher misses it. */
            if (!strcmp(argv[1], "--native-confirm-split")) {
                for (const char *p=prompt; *p; p++) { putchar(*p); fflush(stdout); usleep(1000); }
            } else { printf("%s",prompt); fflush(stdout); }
            if (!fgets(confirmation,sizeof(confirmation),stdin)) return 12;
            if (strcmp(confirmation,"y\n")) return 13;
            if (!strcmp(argv[1], "--native-confirm-again")) {
                printf("%s",prompt); fflush(stdout);
                if (!fgets(confirmation,sizeof(confirmation),stdin)) return 14;
                return 15;
            }
        }
        if (!strcmp(argv[1], "--confirm") || !strcmp(argv[1], "--confirm-again")) {
            printf("Confirm custom boot object? [y/"); fflush(stdout); usleep(20000);
            printf("N]: "); fflush(stdout);
            if (!fgets(confirmation, sizeof(confirmation), stdin)) return 8;
            if (strcmp(confirmation, "y\n")) return 9;
            if (!strcmp(argv[1], "--confirm-again")) {
                printf("Confirm again? (y/n): "); fflush(stdout);
                if (!fgets(confirmation, sizeof(confirmation), stdin)) return 10;
                return 11;
            }
        }
        if (!strcmp(argv[1], "--retry")) {
            password_mode();
            printf("Password: "); fflush(stdout);
            if (!fgets(password, sizeof(password), stdin)) return 2;
            printf("Password: "); fflush(stdout);
            if (!fgets(password, sizeof(password), stdin)) return 3;
            return 4;
        }
        if (!strcmp(argv[1], "--bputil")) {
            alarm(3); /* Bound the regression when an old matcher misses it. */
            printf("Use at your own risk!\n\nAuthorized user: "); fflush(stdout);
            if (!fgets(user,sizeof(user),stdin)) return 16;
            const char *secret=getpass("Password for fixture-user: ");
            return strcmp(user,"fixture-user\n") || !secret || strcmp(secret,"fixture-password") ? 17 : 0;
        }
        if (!strcmp(argv[1], "--bputil-rejected") || !strcmp(argv[1], "--rejected-text-success")) {
            alarm(3);
            printf("Authorized user: "); fflush(stdout);
            if (!fgets(user,sizeof(user),stdin)) return 18;
            if (!getpass("Please enter password for user fixture-user: ")) return 19;
            /* bputil's real output for a wrong password, which exits 8. */
            printf("bputil: failed to set credential: Error Domain=com.apple.LocalAuthentication "
                   "Code=-1 \"Password rejected (3)\"\n"
                   "Failed to create ACM context with provided username and password\n");
            fflush(stdout);
            return strcmp(argv[1], "--bputil-rejected") ? 0 : 8;
        }
        if (!strcmp(argv[1], "--failure-output")) {
            fprintf(stderr,"final command diagnostic\n"); return 42;
        }
        if (!strcmp(argv[1], "--secret-output")) {
            printf("echo: fixture-pass"); fflush(stdout); usleep(20000);
            printf("word\n"); fflush(stdout); return 0;
        }
        printf("Enter the user"); fflush(stdout); usleep(20000);
        printf("name of an admin user: "); fflush(stdout);
        if (!fgets(user, sizeof(user), stdin)) return 5;
        password_mode();
        printf("Pass"); fflush(stdout); usleep(20000);
        printf("word: "); fflush(stdout);
        if (!fgets(password, sizeof(password), stdin)) return 6;
        return strcmp(user,"fixture-user\n") || strcmp(password,"fixture-password\n") ? 7 : 0;
    }
    char *child[] = {argv[0], "--child", NULL};
    int first = authorization_run(argv[0],child,"fixture-user","fixture-password",false);
    fprintf(stderr,"fixture status=%d\n", first);
    assert(first == 0);
    child[1] = "--getpass";
    int tty=authorization_run(argv[0],child,"fixture-user","fixture-password",true);
    if(tty!=0) { fprintf(stderr,"FAIL native getpass: status=%d\n",tty); return 1; }
    child[1] = "--bputil";
    int bputil=authorization_run(argv[0],child,"fixture-user","fixture-password",false);
    if(bputil!=0) { fprintf(stderr,"FAIL bputil authorized user prompt: status=%d\n",bputil); return 1; }
    child[1] = "--native-confirm";
    int native=authorization_run(argv[0],child,"fixture-user","fixture-password",true);
    if(native!=0) { fprintf(stderr,"FAIL native kmutil prompt with newline: status=%d\n",native); return 1; }
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",false) == UNEXPECTED_CONFIRMATION);
    child[1] = "--native-confirm-split";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == 0);
    child[1] = "--native-confirm-again";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == REPEATED_CONFIRMATION);
    child[1] = "--confirm";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == 0);
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",false) == UNEXPECTED_CONFIRMATION);
    child[1] = "--confirm-again";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",true) == REPEATED_CONFIRMATION);
    child[1] = "--retry";
    assert(authorization_run(argv[0],child,"fixture-user","fixture-password",false) == REPEATED_PASSWORD);
    assert(aurora_authorization_password_rejected(REPEATED_PASSWORD));
    assert(aurora_authorization_password_rejected(PASSWORD_REJECTED));
    for(int result=PASSWORD_REJECTED;result<=8;result++)
        assert(result==REPEATED_PASSWORD || result==PASSWORD_REJECTED ||
               !aurora_authorization_password_rejected(result));
    /* The rejection is recognized whatever was typed, even a password that
     * redaction would find inside the rejection lines. */
    child[1] = "--bputil-rejected";
    const char *const typed[]={"fixture-password","word","Password","rejected","ACM"};
    for(size_t i=0;i<sizeof(typed)/sizeof(*typed);i++) {
        int rejected=authorization_run_logged(argv[0],child,"fixture-user",typed[i],false,NULL,NULL);
        if(rejected!=PASSWORD_REJECTED && rejected!=REPEATED_PASSWORD) {
            fprintf(stderr,"FAIL bputil rejection with password %s: status=%d\n",typed[i],rejected);
            return 1;
        }
    }
    /* A command that succeeds never counts as a refusal, whatever it printed. */
    child[1] = "--rejected-text-success";
    int succeeded=authorization_run(argv[0],child,"fixture-user","word",false);
    if(succeeded!=0 && succeeded!=REPEATED_PASSWORD) {
        fprintf(stderr,"FAIL successful command classified: status=%d\n",succeeded); return 1;
    }
    assert(aurora_authorized_command(argv[0],child,"fixture-user","fixture-password") == -1);
    child[1] = "--failure-output";
    assert(authorization_run_logged(argv[0],child,"fixture-user","fixture-password",false,capture,NULL) == 42);
    assert(strstr(latest,"final command diagnostic"));
    child[1] = "--secret-output";
    assert(authorization_run_logged(argv[0],child,"fixture-user","fixture-password",false,capture,NULL) == 0);
    assert(strstr(latest,"[redacted]"));
#ifdef __linux__
    assert(prctl(PR_SET_CHILD_SUBREAPER,1)==0);
#endif
    char *timeout_args[]={argv[0],"--timeout",NULL};
    assert(authorization_run_logged(argv[0],timeout_args,"fixture-user","fixture-password",false,capture,NULL)==TIMED_OUT);
    char *fd_args[]={argv[0],"--fd-check",NULL};
    assert(authorization_run_logged(argv[0],fd_args,"fixture-user","fixture-password",false,capture,NULL)==0);
    char *child_args[]={argv[0],"--grandchild-holds-terminal",NULL};
    assert(authorization_run_logged(argv[0],child_args,"fixture-user","fixture-password",false,capture,NULL)==0);
    assert(strstr(latest,"helper-pid:")!=NULL);
    long helper=0;
    assert(sscanf(strstr(latest,"helper-pid:"),"helper-pid:%ld",&helper)==1 && helper>0);
#ifdef __linux__
    int helper_status=0;
    assert(waitpid((pid_t)helper,&helper_status,0)==(pid_t)helper);
    assert(WIFSIGNALED(helper_status) && WTERMSIG(helper_status)==SIGKILL);
#else
    for(int attempt=0;attempt<100 && kill((pid_t)helper,0)==0;attempt++)usleep(10000);
    assert(kill((pid_t)helper,0)<0 && errno==ESRCH);
#endif

    puts("PASS exact native kmutil prompt / newline / byte-split / repeated prompt; final output / exact exit status / fragmented credential redaction;  split confirmation/username/password prompts; bputil authorized-user prompt; exact one-shot confirmation; unauthorized/repeated confirmation rejection; repeated password rejection and its classification; bputil rejection recognized whatever was typed, never on success; command allowlist");
    return 0;
}
