import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import {
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  redirect,
  RouterProvider,
} from '@tanstack/react-router'
import '@fontsource-variable/geist'
import '@fontsource-variable/geist-mono'
import './index.css'
import { api } from './api'
import { AppToaster, Loading, ThemeProvider } from './components'

const Login = lazy(() => import('./pages/login').then((m) => ({ default: m.Login })))
const Setup = lazy(() => import('./pages/setup').then((m) => ({ default: m.Setup })))
const Account = lazy(() => import('./pages/account').then((m) => ({ default: m.Account })))
const Dashboard = lazy(() => import('./pages/dashboard').then((m) => ({ default: m.Dashboard })))
const Providers = lazy(() => import('./pages/providers').then((m) => ({ default: m.Providers })))
const RouterPage = lazy(() => import('./pages/router').then((m) => ({ default: m.RouterPage })))
const Keys = lazy(() => import('./pages/keys').then((m) => ({ default: m.Keys })))
const Logs = lazy(() => import('./pages/logs').then((m) => ({ default: m.Logs })))
const Audit = lazy(() => import('./pages/audit').then((m) => ({ default: m.Audit })))
const Nodes = lazy(() => import('./pages/nodes').then((m) => ({ default: m.Nodes })))
const Maintenance = lazy(() =>
  import('./pages/maintenance').then((m) => ({ default: m.Maintenance })),
)
const Usage = lazy(() => import('./pages/usage').then((m) => ({ default: m.Usage })))
const Failures = lazy(() => import('./pages/failures').then((m) => ({ default: m.Failures })))

const rootRoute = createRootRoute({
  component: () => (
    <Suspense fallback={<Loading />}>
      <Outlet />
      <AppToaster />
    </Suspense>
  ),
})

// Outside the auth guard: minimal layout, no chrome.
const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: Login,
})

// First-run account bootstrap — also outside the guard.
const setupRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/setup',
  component: Setup,
})

// Console account management (inside the guard).
const accountRoute = createRoute({
  getParentRoute: () => authLayout,
  path: '/account',
  component: Account,
})

// Auth guard: verify the session before any console route renders.
const authLayout = createRoute({
  getParentRoute: () => rootRoute,
  id: '_auth',
  beforeLoad: async () => {
    try {
      await api('/session')
    } catch {
      throw redirect({ to: '/login' })
    }
  },
  component: () => <Outlet />,
})

const indexRoute = createRoute({ getParentRoute: () => authLayout, path: '/', component: Dashboard })
const providersRoute = createRoute({ getParentRoute: () => authLayout, path: '/providers', component: Providers })
const routerRoute = createRoute({ getParentRoute: () => authLayout, path: '/router', component: RouterPage })
const modelsRoute = createRoute({
  getParentRoute: () => authLayout,
  path: '/models',
  beforeLoad: () => {
    throw redirect({ to: '/router' })
  },
})
const keysRoute = createRoute({ getParentRoute: () => authLayout, path: '/keys', component: Keys })
const usageRoute = createRoute({ getParentRoute: () => authLayout, path: '/usage', component: Usage })
const failuresRoute = createRoute({ getParentRoute: () => authLayout, path: '/failures', component: Failures })
const logsRoute = createRoute({ getParentRoute: () => authLayout, path: '/logs', component: Logs })
const nodesRoute = createRoute({ getParentRoute: () => authLayout, path: '/nodes', component: Nodes })
const maintenanceRoute = createRoute({
  getParentRoute: () => authLayout,
  path: '/maintenance',
  component: Maintenance,
})
const auditRoute = createRoute({ getParentRoute: () => authLayout, path: '/audit', component: Audit })

const routeTree = rootRoute.addChildren([
  loginRoute,
  setupRoute,
  authLayout.addChildren([
    accountRoute,
    indexRoute,
    providersRoute,
    routerRoute,
    modelsRoute,
    keysRoute,
    usageRoute,
    failuresRoute,
    nodesRoute,
    maintenanceRoute,
    logsRoute,
    auditRoute,
  ]),
])

// Route-level error boundary. Without this TanStack Router renders its own
// unstyled "Something went wrong!" block that sits outside the app shell.
function RouteError({ error }: { error: unknown }) {
  const message = error instanceof Error ? error.message : String(error ?? "")
  return (
    <div className="flex min-h-svh items-center justify-center bg-background p-6">
      <div className="w-full max-w-md rounded-xl border bg-card p-6 shadow-none">
        <h1 className="text-lg font-semibold tracking-tight">Something went wrong</h1>
        <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
          The console hit an unexpected error while rendering this page.
        </p>
        {message ? (
          <pre className="mt-3 max-h-40 overflow-auto rounded-lg bg-muted p-3 font-mono text-xs whitespace-pre-wrap text-muted-foreground">
            {message}
          </pre>
        ) : null}
        <div className="mt-5 flex gap-2">
          <button
            type="button"
            onClick={() => window.location.reload()}
            className="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Reload
          </button>
          <button
            type="button"
            onClick={() => window.history.back()}
            className="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium transition-colors hover:bg-accent"
          >
            Go back
          </button>
        </div>
      </div>
    </div>
  )
}

const router = createRouter({
  routeTree,
  basepath: '/',
  defaultErrorComponent: RouteError,
  defaultPendingComponent: Loading,
})

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}

const rootElement = document.getElementById('root')
if (!rootElement) throw new Error('main.tsx: index.html is missing #root')
createRoot(rootElement).render(
  <StrictMode>
    <ThemeProvider>
      <RouterProvider router={router} />
    </ThemeProvider>
  </StrictMode>,
)
