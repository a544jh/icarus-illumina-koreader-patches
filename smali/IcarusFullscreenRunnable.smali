.class final Lorg/koreader/launcher/IcarusFullscreenRunnable;
.super Ljava/lang/Object;
.source "IcarusFullscreenRunnable.java"

# interfaces
.implements Ljava/lang/Runnable;


# instance fields
.field private final activity:Lorg/koreader/launcher/MainActivity;


# direct methods
.method constructor <init>(Lorg/koreader/launcher/MainActivity;)V
    .registers 2

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lorg/koreader/launcher/IcarusFullscreenRunnable;->activity:Lorg/koreader/launcher/MainActivity;

    return-void
.end method


# virtual methods
.method public run()V
    .registers 2

    iget-object v0, p0, Lorg/koreader/launcher/IcarusFullscreenRunnable;->activity:Lorg/koreader/launcher/MainActivity;

    invoke-virtual {v0}, Lorg/koreader/launcher/MainActivity;->icarusApplyFullscreenLayout()V

    return-void
.end method
