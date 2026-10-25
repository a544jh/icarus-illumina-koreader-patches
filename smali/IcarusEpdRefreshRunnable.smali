.class final Lorg/koreader/launcher/IcarusEpdRefreshRunnable;
.super Ljava/lang/Object;
.source "IcarusEpdRefreshRunnable.java"

# interfaces
.implements Ljava/lang/Runnable;


# instance fields
.field private final view:Landroid/view/View;


# direct methods
.method constructor <init>(Landroid/view/View;)V
    .registers 2

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lorg/koreader/launcher/IcarusEpdRefreshRunnable;->view:Landroid/view/View;

    return-void
.end method


# virtual methods
.method public run()V
    .registers 3

    iget-object v0, p0, Lorg/koreader/launcher/IcarusEpdRefreshRunnable;->view:Landroid/view/View;

    # Boyue firmware: invalidate(-1010, -1010, -1010, -1010) means full e-ink
    # refresh (requestEpdFullMode(1, 1)); the stock reader's FullFlushAction does the same
    const/16 v1, -0x3f2

    invoke-virtual {v0, v1, v1, v1, v1}, Landroid/view/View;->invalidate(IIII)V

    return-void
.end method
